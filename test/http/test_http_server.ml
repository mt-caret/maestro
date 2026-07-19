open! Core
open! Async
open Maestro_tracker
open Maestro_orchestrator
open Orchestrator
open Maestro_http

let config =
  (Maestro_workflow.Workflow.parse_contents
     {|---
tracker:
  kind: memory
  active_states: [Todo]
  terminal_states: [Done]
---
p|}
     ~workflow_dir:"/unused"
     ~getenv:(fun (_ : string) -> None)
   |> ok_exn)
    .config
;;

let issue ~id ~identifier =
  { Issue.id
  ; native_ref = None
  ; identifier
  ; title = "t"
  ; description = None
  ; priority = None
  ; state = "Todo"
  ; branch_name = None
  ; url = None
  ; assignee_id = None
  ; labels = []
  ; blocked_by = []
  ; dispatchable = true
  ; created_at = None
  ; updated_at = None
  }
;;

(* A snapshot with one running issue, produced by one poll tick. *)
let snapshot_with_one () =
  let adapter = Memory.create ~issues:(fun () -> [ issue ~id:"a" ~identifier:"MT-1" ]) in
  let%map state, _ =
    Orchestrator.handle
      (State.create ())
      ~config
      ~adapter
      ~now:Time_ns.epoch
      ~config_valid:true
      (Orchestrator.Event.Tick { token = None })
  in
  Orchestrator.to_snapshot state ~config ~now:Time_ns.epoch
;;

let get server path =
  let uri =
    Uri.make
      ~scheme:"http"
      ~host:"127.0.0.1"
      ~port:(Http_server.bound_port server)
      ~path
      ()
  in
  let%bind response, body = Cohttp_async.Client.get uri in
  let%map body = Cohttp_async.Body.to_string body in
  Cohttp.Code.code_of_status (Cohttp.Response.status response), body
;;

let post server path =
  let uri =
    Uri.make
      ~scheme:"http"
      ~host:"127.0.0.1"
      ~port:(Http_server.bound_port server)
      ~path
      ()
  in
  let%bind response, body = Cohttp_async.Client.post uri in
  let%map body = Cohttp_async.Body.to_string body in
  Cohttp.Code.code_of_status (Cohttp.Response.status response), body
;;

let field json name =
  match (json : Jsonaf.t) with
  | `Object fields -> List.Assoc.find fields name ~equal:String.equal
  | _ -> None
;;

let%expect_test "endpoints, methods, and errors" =
  let refresh_calls = ref 0 in
  let%bind server =
    Http_server.start
      ~host:"127.0.0.1"
      ~port:0
      ~snapshot:snapshot_with_one
      ~request_refresh:(fun () ->
        incr refresh_calls;
        return (Http_server.Refresh_result.Queued { coalesced = false }))
    >>| ok_exn
  in
  (* GET /api/v1/state -> 200 with counts. *)
  let%bind status, body = get server "/api/v1/state" in
  let json = Jsonaf.of_string body in
  print_s
    [%message "" ~status:(status : int) ~counts:(field json "counts" : Jsonaf.t option)];
  [%expect
    {|
    ((status 200)
     (counts
      ((Object ((running (Number 1)) (retrying (Number 0)) (blocked (Number 0)))))))
    |}];
  (* GET /api/v1/<known> -> 200 running. *)
  let%bind status, body = get server "/api/v1/MT-1" in
  print_s
    [%message
      ""
        ~status:(status : int)
        ~status_field:(field (Jsonaf.of_string body) "status" : Jsonaf.t option)];
  [%expect {| ((status 200) (status_field ((String running)))) |}];
  (* GET /api/v1/<unknown> -> 404 issue_not_found. *)
  let%bind status, body = get server "/api/v1/MT-404" in
  print_s [%message "" ~status:(status : int) ~body:(body : string)];
  [%expect
    {|
    ((status 404)
     (body
      "{\"error\":{\"code\":\"issue_not_found\",\"message\":\"Issue not found\"}}"))
    |}];
  (* POST /api/v1/refresh -> 202. *)
  let%bind status, body = post server "/api/v1/refresh" in
  print_s
    [%message
      ""
        ~status:(status : int)
        ~queued:(field (Jsonaf.of_string body) "queued" : Jsonaf.t option)];
  [%expect {| ((status 202) (queued (True))) |}];
  print_s [%sexp (!refresh_calls : int)];
  [%expect {| 1 |}];
  (* Wrong method on a known route -> 405. *)
  let%bind status, _ = post server "/api/v1/state" in
  print_s [%sexp (status : int)];
  [%expect {| 405 |}];
  (* Unknown route -> 404 not_found. *)
  let%bind status, body = get server "/nope" in
  print_s [%message "" ~status:(status : int) ~body:(body : string)];
  [%expect
    {|
    ((status 404)
     (body "{\"error\":{\"code\":\"not_found\",\"message\":\"Not found\"}}"))
    |}];
  (* Dashboard page at / -> 200 HTML. *)
  let%bind status, body = get server "/" in
  print_s
    [%message
      ""
        ~status:(status : int)
        ~is_html:(String.is_prefix body ~prefix:"<!doctype html>" : bool)];
  [%expect {| ((status 200) (is_html true)) |}];
  let%bind () = Http_server.close server in
  return ()
;;

let%expect_test "refresh returns 503 when the orchestrator is unavailable" =
  let%bind server =
    Http_server.start
      ~host:"127.0.0.1"
      ~port:0
      ~snapshot:snapshot_with_one
      ~request_refresh:(fun () -> return Http_server.Refresh_result.Unavailable)
    >>| ok_exn
  in
  let%bind status, body = post server "/api/v1/refresh" in
  print_s [%message "" ~status:(status : int) ~body:(body : string)];
  [%expect
    {|
    ((status 503)
     (body
      "{\"error\":{\"code\":\"orchestrator_unavailable\",\"message\":\"Orchestrator is unavailable\"}}"))
    |}];
  let%bind () = Http_server.close server in
  return ()
;;
