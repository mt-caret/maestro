open! Core
open! Async
open Maestro_tracker
open Maestro_orchestrator
open Orchestrator
open Harness

let ms = Time_ns.Span.of_int_ms

let%expect_test "dispatch order: priority 1..4, then oldest created_at, then identifier" =
  let t = create () in
  let at s = Some (Time_ns.add Time_ns.epoch (Time_ns.Span.of_int_sec s)) in
  t.issues
  <- [ issue ~id:"a" ~identifier:"MT-3" ~priority:None ~created_at:(at 10) ()
     ; issue ~id:"b" ~identifier:"MT-1" ~priority:(Some 2) ~created_at:(at 30) ()
     ; issue ~id:"c" ~identifier:"MT-2" ~priority:(Some 2) ~created_at:(at 20) ()
     ; issue ~id:"d" ~identifier:"MT-9" ~priority:(Some 1) ~created_at:None ()
     ; issue ~id:"e" ~identifier:"MT-0" ~priority:(Some 7) ~created_at:(at 5) ()
     ];
  (* Only 2 concurrent slots, so we see the top-2 in order. *)
  let%bind spawned = poll t in
  print_s [%sexp (dispatched_identifiers spawned : string list)];
  [%expect {| (MT-9 MT-2) |}];
  return ()
;;

let%expect_test "eligibility: dispatchable=false and required-label filtering" =
  let t =
    create
      ~config_yaml:
        {|---
tracker:
  kind: memory
  active_states: [Todo]
  terminal_states: [Done]
  required_labels: [backend]
agent:
  max_concurrent_agents: 5
---
p|}
      ()
  in
  t.issues
  <- [ issue ~id:"a" ~identifier:"MT-1" ~labels:[ "backend" ] ()
     ; issue ~id:"b" ~identifier:"MT-2" ~labels:[ "frontend" ] ()
     ; issue ~id:"c" ~identifier:"MT-3" ~labels:[ "backend" ] ~dispatchable:false ()
     ; issue ~id:"d" ~identifier:"MT-4" ~state:"Done" ~labels:[ "backend" ] ()
     ];
  let%bind spawned = poll t in
  print_s [%sexp (dispatched_identifiers spawned : string list)];
  [%expect {| (MT-1) |}];
  return ()
;;

let%expect_test "global and per-state concurrency slots" =
  let t =
    create
      ~config_yaml:
        {|---
tracker:
  kind: memory
  active_states: [Todo, In Progress]
  terminal_states: [Done]
agent:
  max_concurrent_agents: 3
  max_concurrent_agents_by_state:
    todo: 1
---
p|}
      ()
  in
  t.issues
  <- [ issue ~id:"a" ~identifier:"MT-1" ~state:"Todo" ()
     ; issue ~id:"b" ~identifier:"MT-2" ~state:"Todo" ()
     ; issue ~id:"c" ~identifier:"MT-3" ~state:"In Progress" ()
     ; issue ~id:"d" ~identifier:"MT-4" ~state:"In Progress" ()
     ];
  (* todo capped at 1; global at 3 -> one Todo + two In Progress. *)
  let%bind spawned = poll t in
  print_s
    [%sexp
      (List.sort (dispatched_identifiers spawned) ~compare:String.compare : string list)];
  [%expect {| (MT-1 MT-3 MT-4) |}];
  return ()
;;

let%expect_test "normal exit schedules a 1s continuation retry; failure uses 10s backoff" =
  let t = create () in
  t.issues <- [ issue ~id:"a" ~identifier:"MT-1" () ];
  let%bind spawned = poll t in
  let _, _, run_token = List.hd_exn spawned in
  (* Clean exit -> continuation retry attempt 1 at 1000ms; issue stays claimed. *)
  let%bind effects =
    feed t (Worker_exited { issue_id = "a"; run_token; outcome = Completed })
  in
  let show_retry effects =
    List.map (retries effects) ~f:(fun (id, delay, _) -> id, delay)
    |> [%sexp_of: (string * Time_ns.Span.t) list]
    |> print_s
  in
  show_retry effects;
  [%expect {| ((a 1s)) |}];
  print_s [%sexp (Set.to_list (State.claimed t.state) : string list)];
  [%expect {| (a) |}];
  (* A second worker for a different issue that fails -> 10s backoff, attempt 1. *)
  t.issues <- t.issues @ [ issue ~id:"b" ~identifier:"MT-2" () ];
  let%bind spawned = poll t in
  let _, _, run_token_b =
    List.find_exn spawned ~f:(fun (issue, _, _) -> String.equal issue.Issue.id "b")
  in
  let%bind effects =
    feed
      t
      (Worker_exited { issue_id = "b"; run_token = run_token_b; outcome = Failed "boom" })
  in
  show_retry effects;
  [%expect {| ((b 10s)) |}];
  return ()
;;

let%expect_test "failure backoff doubles and caps" =
  let t =
    create
      ~config_yaml:
        {|---
tracker:
  kind: memory
  active_states: [Todo]
  terminal_states: [Done]
agent:
  max_concurrent_agents: 1
  max_retry_backoff_ms: 45000
---
p|}
      ()
  in
  t.issues <- [ issue ~id:"a" ~identifier:"MT-1" () ];
  (* Fail repeatedly. Each failure schedules the next retry; firing it re-dispatches (that
     spawn's run_token drives the next failure). *)
  let%bind spawned = poll t in
  let rec fail_n run_token n ~acc =
    match n with
    | 0 -> return (List.rev acc)
    | n ->
      let%bind effects =
        feed t (Worker_exited { issue_id = "a"; run_token; outcome = Failed "x" })
      in
      (match retries effects with
       | [ (_, delay, token) ] ->
         advance t delay;
         let%bind effects = feed t (Retry_due { issue_id = "a"; token }) in
         (match spawns effects with
          | [ (_, _, run_token) ] -> fail_n run_token (n - 1) ~acc:(delay :: acc)
          | _ -> failwith "retry should have re-dispatched")
       | _ -> failwith "expected one retry")
  in
  let _, _, run_token = List.hd_exn spawned in
  let%bind delays = fail_n run_token 4 ~acc:[] in
  print_s [%sexp (delays : Time_ns.Span.t list)];
  (* 10s, 20s, 40s, then capped at 45s. *)
  [%expect {| (10s 20s 40s 45s) |}];
  return ()
;;

let%expect_test "reconciliation: active update, non-active stop, terminal stop+cleanup, \
                 missing stop"
  =
  let t = create () in
  t.issues
  <- [ issue ~id:"a" ~identifier:"MT-1" ~state:"Todo" ()
     ; issue ~id:"b" ~identifier:"MT-2" ~state:"Todo" ()
     ];
  let%bind (_ : _ list) = poll t in
  print_s [%sexp (List.length (snapshot t).running : int)];
  [%expect {| 2 |}];
  (* MT-1 moves to a terminal state (cleanup), MT-2 vanishes from the tracker. *)
  t.issues <- [ { (issue ~id:"a" ~identifier:"MT-1" ()) with state = "Done" } ];
  let%bind effects = feed t (Tick { token = None }) in
  print_s
    [%message
      ""
        ~running:
          (List.map (snapshot t).running ~f:(fun r -> r.issue_identifier) : string list)
        ~stopped:(stops effects : string list)
        ~removed:(t.removed_workspaces : string list)];
  [%expect {| ((running ()) (stopped (a b)) (removed (MT-1))) |}];
  return ()
;;

let%expect_test "reconciliation fetch failure keeps all running workers" =
  let t = create () in
  t.issues <- [ issue ~id:"a" ~identifier:"MT-1" (); issue ~id:"b" ~identifier:"MT-2" () ];
  let%bind (_ : _ list) = poll t in
  print_s [%sexp (List.length (snapshot t).running : int)];
  [%expect {| 2 |}];
  t.ids_error <- Some "tracker down";
  let%bind effects = feed t (Tick { token = None }) in
  print_s
    [%message
      ""
        ~running:(List.length (snapshot t).running : int)
        ~stopped:(stops effects : string list)];
  [%expect {| ((running 2) (stopped ())) |}];
  return ()
;;

let%expect_test "retry-fire tracker error requeues attempt+1 and keeps the claim" =
  let t = create () in
  t.issues <- [ issue ~id:"a" ~identifier:"MT-1" () ];
  let%bind spawned = poll t in
  let _, _, run_token = List.hd_exn spawned in
  let%bind effects =
    feed t (Worker_exited { issue_id = "a"; run_token; outcome = Failed "x" })
  in
  let _, _, token = List.hd_exn (List.map (retries effects) ~f:Fn.id) in
  advance t (ms 10_000);
  t.ids_error <- Some "tracker down";
  let%bind effects = feed t (Retry_due { issue_id = "a"; token }) in
  let requeued = List.map (retries effects) ~f:(fun (id, _, _) -> id) in
  print_s
    [%message
      ""
        ~requeued:(requeued : string list)
        ~claimed:(Set.to_list (State.claimed t.state) : string list)
        ~retry_error:
          (List.map (snapshot t).retrying ~f:(fun r -> r.error) : string option list)
        ~attempt:(List.map (snapshot t).retrying ~f:(fun r -> r.attempt) : int list)];
  [%expect
    {|
    ((requeued (a)) (claimed (a)) (retry_error (("retry poll failed")))
     (attempt (2)))
    |}];
  return ()
;;

let%expect_test "slot exhaustion at retry-fire requeues with an explicit error" =
  let t =
    create
      ~config_yaml:
        {|---
tracker:
  kind: memory
  active_states: [Todo]
  terminal_states: [Done]
agent:
  max_concurrent_agents: 1
---
p|}
      ()
  in
  t.issues <- [ issue ~id:"a" ~identifier:"MT-1" (); issue ~id:"b" ~identifier:"MT-2" () ];
  (* One slot: MT-1 dispatches, MT-2 does not. Fail MT-1 to queue a retry, then keep the
     slot busy with MT-1's replacement so MT-2... actually make MT-1 fail and a new run
     occupy the slot, then fire MT-2 is not queued. Instead: dispatch MT-1, fail it (retry
     queued), refill slot via poll, then fire MT-1's retry with no slot. *)
  let%bind spawned = poll t in
  let _, _, run_token = List.hd_exn spawned in
  let%bind effects =
    feed t (Worker_exited { issue_id = "a"; run_token; outcome = Failed "x" })
  in
  let _, _, token = List.hd_exn (List.map (retries effects) ~f:Fn.id) in
  (* Occupy the single slot with MT-2 before MT-1's retry fires. *)
  let%bind (_ : _ list) = poll t in
  print_s
    [%sexp (List.map (snapshot t).running ~f:(fun r -> r.issue_identifier) : string list)];
  [%expect {| (MT-2) |}];
  advance t (ms 10_000);
  let%bind effects = feed t (Retry_due { issue_id = "a"; token }) in
  print_s
    [%message
      ""
        ~requeued:(List.map (retries effects) ~f:(fun (id, _, _) -> id) : string list)
        ~error:(List.filter_map (snapshot t).retrying ~f:(fun r -> r.error) : string list)];
  [%expect {| ((requeued (a)) (error ("no available orchestrator slots"))) |}];
  return ()
;;

let%expect_test "config_valid=false blocks new dispatch but still reconciles" =
  let t = create () in
  t.issues <- [ issue ~id:"a" ~identifier:"MT-1" () ];
  (* A currently-invalid workflow file: the tick reconciles but must not dispatch. *)
  let%bind effects = feed ~config_valid:false t (Tick { token = None }) in
  print_s [%message "" ~spawned:(dispatched_identifiers (spawns effects) : string list)];
  [%expect {| (spawned ()) |}];
  (* Once valid again, the same issue dispatches. *)
  let%bind spawned = poll t in
  print_s [%sexp (dispatched_identifiers spawned : string list)];
  [%expect {| (MT-1) |}];
  return ()
;;

let%expect_test "stall detection kills the worker and schedules a retry" =
  let t =
    create
      ~config_yaml:
        {|---
tracker:
  kind: memory
  active_states: [Todo]
  terminal_states: [Done]
codex:
  stall_timeout_ms: 5000
---
p|}
      ()
  in
  t.issues <- [ issue ~id:"a" ~identifier:"MT-1" () ];
  let%bind (_ : _ list) = poll t in
  (* No codex activity for longer than the stall timeout. *)
  advance t (ms 6_000);
  let%bind effects = feed t (Tick { token = None }) in
  print_s
    [%message
      ""
        ~stopped:(stops effects : string list)
        ~retry:(List.map (retries effects) ~f:(fun (id, _, _) -> id) : string list)
        ~running:(List.length (snapshot t).running : int)];
  [%expect {| ((stopped (a)) (retry (a)) (running 0)) |}];
  return ()
;;

let%expect_test "token accounting: high-water absolute totals, deltas ignored" =
  let t = create () in
  t.issues <- [ issue ~id:"a" ~identifier:"MT-1" () ];
  let%bind spawned = poll t in
  let _, _, (_ : Token.t) = List.hd_exn spawned in
  let update ~payload =
    { Maestro_codex.Update.event = Notification
    ; timestamp = t.now
    ; codex_app_server_pid = None
    ; session_id = None
    ; payload = Some (Jsonaf.of_string payload)
    ; detail = None
    }
  in
  let feed_update payload =
    feed t (Codex_update { issue_id = "a"; update = update ~payload })
  in
  (* Two absolute cumulative snapshots via thread/tokenUsage/updated: totals track the
     latest, not the sum. *)
  let%bind (_ : _ list) =
    feed_update
      {|{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"total":{"input_tokens":10,"output_tokens":4,"total_tokens":14},"last":{"total_tokens":14}}}}|}
  in
  let%bind (_ : _ list) =
    feed_update
      {|{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"total":{"input_tokens":11,"output_tokens":6,"total_tokens":17},"last":{"total_tokens":3}}}}|}
  in
  (* A payload carrying only a delta contributes nothing. *)
  let%bind (_ : _ list) =
    feed_update
      {|{"method":"notification","params":{"last_token_usage":{"total_tokens":99}}}|}
  in
  let totals = (snapshot t).codex_totals in
  print_s
    [%message
      ""
        ~input:(totals.input_tokens : int)
        ~output:(totals.output_tokens : int)
        ~total:(totals.total_tokens : int)];
  [%expect {| ((input 11) (output 6) (total 17)) |}];
  return ()
;;

let%expect_test "input-blocked worker exit parks the issue as blocked, not retried" =
  let t = create () in
  t.issues <- [ issue ~id:"a" ~identifier:"MT-1" () ];
  let%bind spawned = poll t in
  let _, _, run_token = List.hd_exn spawned in
  let approval_update =
    { Maestro_codex.Update.event = Approval_required
    ; timestamp = t.now
    ; codex_app_server_pid = None
    ; session_id = None
    ; payload = None
    ; detail = None
    }
  in
  let%bind (_ : _ list) =
    feed t (Codex_update { issue_id = "a"; update = approval_update })
  in
  let%bind effects =
    feed t (Worker_exited { issue_id = "a"; run_token; outcome = Failed "input" })
  in
  print_s
    [%message
      ""
        ~retries:(List.map (retries effects) ~f:(fun (id, _, _) -> id) : string list)
        ~blocked:
          (List.map (snapshot t).blocked ~f:(fun b -> b.issue_identifier) : string list)
        ~claimed:(Set.to_list (State.claimed t.state) : string list)];
  [%expect {| ((retries ()) (blocked (MT-1)) (claimed (a))) |}];
  (* Reconciliation: the blocked issue reaching a terminal state cleans up and releases. *)
  t.issues <- [ { (issue ~id:"a" ~identifier:"MT-1" ()) with state = "Done" } ];
  let%bind (_ : _ list) = feed t (Tick { token = None }) in
  print_s
    [%message
      ""
        ~blocked:(List.length (snapshot t).blocked : int)
        ~claimed:(Set.to_list (State.claimed t.state) : string list)
        ~removed:(t.removed_workspaces : string list)];
  [%expect {| ((blocked 0) (claimed ()) (removed (MT-1))) |}];
  return ()
;;

let%expect_test "continuation re-dispatch: still-active issue runs again after the 1s \
                 retry"
  =
  let t = create () in
  t.issues <- [ issue ~id:"a" ~identifier:"MT-1" () ];
  let%bind spawned = poll t in
  let _, _, run_token = List.hd_exn spawned in
  let%bind effects =
    feed t (Worker_exited { issue_id = "a"; run_token; outcome = Completed })
  in
  let _, delay, token = List.hd_exn (retries effects) in
  advance t delay;
  let%bind effects = feed t (Retry_due { issue_id = "a"; token }) in
  print_s [%sexp (dispatched_identifiers (spawns effects) : string list)];
  [%expect {| (MT-1) |}];
  return ()
;;

let%expect_test "snapshot shape" =
  let t = create () in
  t.issues <- [ issue ~id:"a" ~identifier:"MT-1" ~priority:(Some 2) () ];
  let%bind spawned = poll t in
  let _, _, (_ : Token.t) = List.hd_exn spawned in
  let started_update =
    { Maestro_codex.Update.event = Session_started
    ; timestamp = t.now
    ; codex_app_server_pid = None
    ; session_id = Some "th-1-tu-1"
    ; payload = Some (Jsonaf.of_string {|{"method":"turn/started"}|})
    ; detail = None
    }
  in
  let%bind (_ : _ list) =
    feed t (Codex_update { issue_id = "a"; update = started_update })
  in
  advance t (Time_ns.Span.of_int_sec 5);
  print_s [%sexp (snapshot t : Snapshot.t)];
  [%expect
    {|
    ((running
      (((issue_id a) (issue_identifier MT-1) (issue_url (https://tracker/MT-1))
        (state Todo) (session_id (th-1-tu-1)) (turn_count 1)
        (last_event (Session_started))
        (last_message ("session started (th-1-tu-1)"))
        (started_at (1970-01-01 00:00:00.000000000Z))
        (last_event_at ((1970-01-01 00:00:00.000000000Z)))
        (recent_events
         (((at (1970-01-01 00:00:00.000000000Z)) (event Session_started)
           (message "session started (th-1-tu-1)"))))
        (workspace_path ())
        (tokens ((input_tokens 0) (output_tokens 0) (total_tokens 0)))
        (runtime_seconds 5))))
     (retrying ()) (blocked ())
     (codex_totals
      ((input_tokens 0) (output_tokens 0) (total_tokens 0) (seconds_running 5)))
     (rate_limits ())
     (polling
      ((checking false) (next_poll_in_ms (25000)) (poll_interval_ms 30000))))
    |}];
  return ()
;;
