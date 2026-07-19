open! Core
open Maestro_orchestrator

let usage payload =
  Token_accounting.absolute_usage (Jsonaf.of_string payload)
  |> [%sexp_of: Token_accounting.Usage.t option]
  |> print_s
;;

let%expect_test "absolute usage: path precedence and delta rejection" =
  (* thread/tokenUsage/updated total. *)
  usage
    {|{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"total":{"input_tokens":10,"output_tokens":4,"total_tokens":14},"last":{"total_tokens":3}}}}|};
  [%expect {| (((input 10) (output 4) (total 14))) |}];
  (* codex/event/token_count wrapper: params.msg.payload.info.total_token_usage. *)
  usage
    {|{"params":{"msg":{"payload":{"info":{"total_token_usage":{"prompt_tokens":7,"completion_tokens":2,"total_tokens":9}}}}}}|};
  [%expect {| (((input 7) (output 2) (total 9))) |}];
  (* turn/completed usage is a valid fallback. *)
  usage
    {|{"method":"turn/completed","usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}|};
  [%expect {| (((input 1) (output 2) (total 3))) |}];
  (* A payload with only last_token_usage yields no absolute usage. *)
  usage {|{"method":"notification","last_token_usage":{"total_tokens":50}}|};
  [%expect {| () |}];
  (* String-valued numbers parse leniently. *)
  usage {|{"tokenUsage":{"total":{"inputTokens":"12","totalTokens":"12abc"}}}|};
  [%expect {| (((input 12) (output 0) (total 12))) |}]
;;

let%expect_test "counters accumulate deltas over the high-water mark" =
  let counters = Token_accounting.Counters.empty in
  let step counters payload =
    let usage =
      Option.value_exn (Token_accounting.absolute_usage (Jsonaf.of_string payload))
    in
    let counters, delta = Token_accounting.Counters.apply counters usage in
    print_s
      [%message
        ""
          ~total:(Token_accounting.Counters.total counters : int)
          ~delta:(delta.total : int)];
    counters
  in
  let counters = step counters {|{"tokenUsage":{"total":{"total_tokens":14}}}|} in
  [%expect {| ((total 14) (delta 14)) |}];
  (* A re-reported cumulative snapshot of 17 adds only the delta of 3. *)
  let counters = step counters {|{"tokenUsage":{"total":{"total_tokens":17}}}|} in
  [%expect {| ((total 17) (delta 3)) |}];
  (* A lower snapshot never decreases the total. *)
  let (_ : Token_accounting.Counters.t) =
    step counters {|{"tokenUsage":{"total":{"total_tokens":15}}}|}
  in
  [%expect {| ((total 17) (delta 0)) |}]
;;

let%expect_test "rate limits: depth-first, verbatim, gated on the shape" =
  let show payload =
    Token_accounting.rate_limits (Jsonaf.of_string payload)
    |> [%sexp_of: Jsonaf.t option]
    |> print_s
  in
  show
    {|{"params":{"msg":{"payload":{"rate_limits":{"limit_id":"codex","primary":{"remaining":90,"limit":100},"credits":{"has_credits":false}}}}}}|};
  [%expect
    {|
    ((Object
      ((limit_id (String codex))
       (primary (Object ((remaining (Number 90)) (limit (Number 100)))))
       (credits (Object ((has_credits False)))))))
    |}];
  (* A map with a limit id but none of primary/secondary/credits is not a match. *)
  show {|{"limit_id":"codex","other":1}|};
  [%expect {| () |}]
;;
