open! Core
open Maestro_orchestrator

let ms = Time_ns.Span.of_int_ms

let%expect_test "failure backoff schedule and cap" =
  let cap = ms 300_000 in
  List.init 6 ~f:(fun i -> Dispatch_policy.failure_backoff ~attempt:(i + 1) ~cap)
  |> [%sexp_of: Time_ns.Span.t list]
  |> print_s;
  (* 10s, 20s, 40s, 80s, 160s, then capped at 300s. *)
  [%expect {| (10s 20s 40s 1m20s 2m40s 5m) |}];
  print_s [%sexp (Dispatch_policy.continuation_delay : Time_ns.Span.t)];
  [%expect {| 1s |}]
;;
