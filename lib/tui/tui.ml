open! Core
open! Async
open Bonsai_term
module Var = Bonsai.Expert.Var

let app ~snapshot_var ~request_refresh ~dashboard_url ~exit ~dimensions (local_ graph) =
  let open Bonsai.Let_syntax in
  let snapshot = Var.value snapshot_var in
  let selected_value, set_selected = Bonsai.state 0 graph in
  let view =
    let%map snapshot
    and selected = selected_value
    and dimensions in
    Dashboard.view { snapshot; selected; dashboard_url } ~dimensions
  in
  let handler =
    let%map snapshot
    and selected = selected_value
    and set_selected in
    fun (event : Event.t) ->
      let count = Dashboard.selectable_count { snapshot; selected; dashboard_url } in
      match event with
      | Key_press { key = ASCII ('q' | 'Q'); mods = _ }
      | Key_press { key = Escape; mods = _ } -> exit ()
      | Key_press { key = Arrow `Up; mods = _ } | Key_press { key = ASCII 'k'; mods = _ }
        -> set_selected (Int.max 0 (selected - 1))
      | Key_press { key = Arrow `Down; mods = _ }
      | Key_press { key = ASCII 'j'; mods = _ } ->
        set_selected (Int.min (Int.max 0 (count - 1)) (selected + 1))
      | Key_press { key = ASCII 'r'; mods = _ } ->
        Effect.of_deferred_thunk (fun () -> request_refresh ())
      | Key_press _ | Mouse _ | Paste _ -> Effect.return ()
  in
  ~view, ~handler
;;

let run ~snapshot ~request_refresh ~dashboard_url ~refresh =
  let%bind initial = snapshot () in
  let snapshot_var = Var.create initial in
  let stop = Ivar.create () in
  Clock_ns.every' ~stop:(Ivar.read stop) ~continue_on_error:true refresh (fun () ->
    let%map latest = snapshot () in
    Var.set snapshot_var latest);
  let%map result =
    Bonsai_term.start_with_exit (fun ~exit ~dimensions graph ->
      app ~snapshot_var ~request_refresh ~dashboard_url ~exit ~dimensions graph)
  in
  Ivar.fill_if_empty stop ();
  result
;;
