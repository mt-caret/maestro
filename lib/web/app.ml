open! Core
open! Async_kernel
open Bonsai_web
module Http_api = Maestro_snapshot.Http_api

let fetch decode path =
  let%bind.Deferred.Or_error body = Async_js.Http.get path in
  Deferred.return (decode body)
;;

let empty_state =
  { Http_api.State.generated_at = Time_ns.epoch
  ; counts = { running = 0; retrying = 0; blocked = 0 }
  ; running = []
  ; retrying = []
  ; blocked = []
  ; codex_totals =
      { input_tokens = 0; output_tokens = 0; total_tokens = 0; seconds_running = 0. }
  ; rate_limits = None
  }
;;

let component (local_ graph) =
  let state, set_state = Bonsai.state None graph in
  let refresh =
    let open Bonsai.Let_syntax in
    let%arr set_state in
    let%bind.Effect result =
      Effect.of_deferred_thunk (fun () -> fetch Http_api.decode_state "/api/v1/state")
    in
    set_state (Some result)
  in
  Bonsai.Clock.every
    ~when_to_start_next_effect:`Every_multiple_of_period_blocking
    ~trigger_on_activate:true
    (Bonsai.return (Time_ns.Span.of_sec 1.))
    refresh
    graph;
  let state =
    let open Bonsai.Let_syntax in
    let%map state in
    Option.bind state ~f:Result.ok |> Option.value ~default:empty_state
  in
  Dashboard.component
    state
    ~fetch_detail:(fun identifier ->
      Effect.of_deferred_thunk (fun () ->
        fetch Http_api.decode_detail [%string "/api/v1/%{Uri.pct_encode identifier}"]))
    graph
;;
