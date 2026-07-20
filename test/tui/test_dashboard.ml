open! Core
open Bonsai_term
open Maestro_orchestrator
open Maestro_tui

let tokens ~input ~output ~total =
  { Snapshot.Tokens.input_tokens = input; output_tokens = output; total_tokens = total }
;;

let running ~identifier ~state ~turn ~total ~session ~last =
  { Snapshot.Running.issue_id = String.lowercase identifier
  ; issue_identifier = identifier
  ; issue_url = Some [%string "https://tracker/%{identifier}"]
  ; state
  ; session_id = session
  ; turn_count = turn
  ; last_event = Some "Turn_completed"
  ; last_message = Some last
  ; started_at = Time_ns.epoch
  ; last_event_at = Some Time_ns.epoch
  ; recent_events = []
  ; workspace_path = Some [%string "/tmp/ws/%{identifier}"]
  ; tokens = tokens ~input:(total / 2) ~output:(total / 2) ~total
  ; runtime_seconds = 785.
  }
;;

let sample_snapshot =
  { Snapshot.running =
      [ running
          ~identifier:"MT-101"
          ~state:"In Progress"
          ~turn:11
          ~total:120450
          ~session:(Some "thread-abcdef-turn-1")
          ~last:"turn completed"
      ; running
          ~identifier:"MT-104"
          ~state:"In Progress"
          ~turn:3
          ~total:18020
          ~session:(Some "thread-ghijkl-turn-2")
          ~last:"exec: dune build"
      ]
  ; retrying =
      [ { Snapshot.Retrying.issue_id = "mt-450"
        ; issue_identifier = "MT-450"
        ; issue_url = None
        ; attempt = 4
        ; due_in_ms = 1250
        ; error = Some "rate limit exhausted"
        ; workspace_path = None
        }
      ]
  ; blocked =
      [ { Snapshot.Blocked.issue_id = "mt-333"
        ; issue_identifier = "MT-333"
        ; issue_url = None
        ; state = Some "In Progress"
        ; session_id = None
        ; error = Some "approval required"
        ; blocked_at = Time_ns.epoch
        ; last_event = None
        ; last_message = None
        ; recent_events = []
        }
      ]
  ; codex_totals =
      { input_tokens = 120450
      ; output_tokens = 45020
      ; total_tokens = 165470
      ; seconds_running = 1834.
      }
  ; rate_limits = None
  ; polling = { checking = false; next_poll_in_ms = Some 4200; poll_interval_ms = 5000 }
  }
;;

let dims = { Dimensions.width = 96; height = 24 }

let%expect_test "dashboard layout with a selection" =
  Bonsai_term_test.print_view
    (Dashboard.view
       { snapshot = sample_snapshot
       ; selected = 0
       ; dashboard_url = Some "http://127.0.0.1:8080/"
       }
       ~dimensions:dims);
  [%expect
    {|
    MAESTRO  agents 2  backoff 1  blocked 1
    tokens in 120,450  out 45,020   runtime 30m 34s   poll in 5s
    dashboard http://127.0.0.1:8080/
    Running                                                   Detail: MT-101
      ID        STATE       TURN TOKENS    EVENT              state     In Progress
    ▸ MT-101    In Progress 11   120,450   turn complet…      session   thread-abcdef-turn-1
      MT-104    In Progress 3    18,020    exec: dune bui…    turn      11
    Backoff queue                                             tokens    in 60,225 / out 60,225
      ↻ MT-450     attempt=4 in 2s  rate limit exhausted      runtime   13m 5s
    Blocked                                                   workspace /tmp/ws/MT-101
      ● MT-333     approval required                          last      turn completed
    ↑↓ select · r refresh · q quit
    |}]
;;

let%expect_test "selection moves the marker and detail; out-of-range clamps to last" =
  let render selected =
    Bonsai_term_test.print_view
      (Dashboard.view
         { snapshot = sample_snapshot; selected; dashboard_url = None }
         ~dimensions:dims)
  in
  render 1;
  [%expect
    {|
    MAESTRO  agents 2  backoff 1  blocked 1
    tokens in 120,450  out 45,020   runtime 30m 34s   poll in 5s
    Running                                                   Detail: MT-104
      ID        STATE       TURN TOKENS    EVENT              state     In Progress
      MT-101    In Progress 11   120,450   turn completed     session   thread-ghijkl-turn-2
    ▸ MT-104    In Progress 3    18,020    exec: dune b…      turn      3
    Backoff queue                                             tokens    in 9,010 / out 9,010
      ↻ MT-450     attempt=4 in 2s  rate limit exhausted      runtime   13m 5s
    Blocked                                                   workspace /tmp/ws/MT-104
      ● MT-333     approval required                          last      exec: dune build
    ↑↓ select · r refresh · q quit
    |}];
  (* Index past the end clamps to the last running row. *)
  render 9;
  [%expect
    {|
    MAESTRO  agents 2  backoff 1  blocked 1
    tokens in 120,450  out 45,020   runtime 30m 34s   poll in 5s
    Running                                                   Detail: MT-104
      ID        STATE       TURN TOKENS    EVENT              state     In Progress
      MT-101    In Progress 11   120,450   turn completed     session   thread-ghijkl-turn-2
    ▸ MT-104    In Progress 3    18,020    exec: dune b…      turn      3
    Backoff queue                                             tokens    in 9,010 / out 9,010
      ↻ MT-450     attempt=4 in 2s  rate limit exhausted      runtime   13m 5s
    Blocked                                                   workspace /tmp/ws/MT-104
      ● MT-333     approval required                          last      exec: dune build
    ↑↓ select · r refresh · q quit
    |}]
;;

let%expect_test "empty state" =
  let empty =
    { Snapshot.running = []
    ; retrying = []
    ; blocked = []
    ; codex_totals =
        { input_tokens = 0; output_tokens = 0; total_tokens = 0; seconds_running = 0. }
    ; rate_limits = None
    ; polling =
        { checking = false; next_poll_in_ms = Some 30000; poll_interval_ms = 30000 }
    }
  in
  Bonsai_term_test.print_view
    (Dashboard.view
       { snapshot = empty; selected = 0; dashboard_url = None }
       ~dimensions:dims);
  [%expect
    {|
    MAESTRO  agents 0  backoff 0  blocked 0
    tokens in 0  out 0   runtime 0m 0s   poll in 30s
    Running                                                   Detail
      ID        STATE       TURN TOKENS    EVENT                select a running agent
      no active agents
    Backoff queue
      no queued retries
    ↑↓ select · r refresh · q quit
    |}]
;;
