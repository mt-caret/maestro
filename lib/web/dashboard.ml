open! Core
open Bonsai_web
module Http_api = Maestro_snapshot.Http_api

let text = Vdom.Node.text
let commas n = Int.to_string_hum n ~delimiter:','
let option_text = Option.value ~default:"–"

let seconds seconds =
  [%string "%{Int.of_float seconds / 60#Int}m %{Int.of_float seconds % 60#Int}s"]
;;

let td s = Vdom.Node.td [ text s ]
let th s = Vdom.Node.th [ text s ]

let issue_button ~select identifier =
  Vdom.Node.button
    ~attrs:[ Vdom.Attr.class_ "issue"; Vdom.Attr.on_click (fun _ -> select identifier) ]
    [ text identifier ]
;;

let table ~title ~headers rows =
  Vdom.Node.section
    [ Vdom.Node.h2 [ text [%string "%{title} (%{List.length rows#Int})"] ]
    ; Vdom.Node.table
        [ Vdom.Node.thead [ Vdom.Node.tr (List.map headers ~f:th) ]
        ; Vdom.Node.tbody
            (if List.is_empty rows
             then
               [ Vdom.Node.tr
                   [ Vdom.Node.td
                       ~attrs:[ Vdom.Attr.colspan (List.length headers) ]
                       [ text "none" ]
                   ]
               ]
             else rows)
        ]
    ]
;;

let detail_view selected detail =
  let line label value =
    Vdom.Node.div [ Vdom.Node.dt [ text label ]; Vdom.Node.dd [ text value ] ]
  in
  let body =
    match selected, detail with
    | None, _ -> [ Vdom.Node.p [ text "Select an issue." ] ]
    | Some _, None -> [ Vdom.Node.p [ text "Loading…" ] ]
    | Some _, Some (Error error) ->
      [ Vdom.Node.p
          ~attrs:[ Vdom.Attr.class_ "error" ]
          [ text (Error.to_string_hum error) ]
      ]
    | Some _, Some (Ok (detail : Http_api.Detail.t)) ->
      (match detail.running, detail.retry, detail.blocked with
       | Some row, _, _ ->
         [ Vdom.Node.dl
             [ line "Status" detail.status
             ; line "State" row.state
             ; line "Session" (option_text row.session_id)
             ; line "Turn" (Int.to_string row.turn_count)
             ; line
                 "Tokens"
                 [%string
                   "in %{commas row.tokens.input_tokens} / out %{commas \
                    row.tokens.output_tokens}"]
             ; line "Runtime" (seconds row.runtime_seconds)
             ; line "Workspace" (option_text row.workspace_path)
             ; line "Last" (option_text row.last_message)
             ]
         ]
       | None, Some row, _ ->
         [ Vdom.Node.dl
             [ line "Status" detail.status
             ; line "Attempt" (Int.to_string row.attempt)
             ; line "Error" (option_text row.error)
             ]
         ]
       | None, None, Some row ->
         [ Vdom.Node.dl
             [ line "Status" detail.status
             ; line "State" (option_text row.state)
             ; line "Error" (option_text row.error)
             ]
         ]
       | None, None, None -> [ Vdom.Node.p [ text "Issue is no longer active." ] ])
  in
  Vdom.Node.aside (Vdom.Node.h2 [ text "Detail" ] :: body)
;;

let view (state : Http_api.State.t) ~selected ~detail ~select =
  let running =
    List.map state.running ~f:(fun row ->
      Vdom.Node.tr
        [ Vdom.Node.td [ issue_button ~select row.issue_identifier ]
        ; td row.state
        ; td (Int.to_string row.turn_count)
        ; td (commas row.tokens.total_tokens)
        ; td (option_text row.last_message)
        ])
  in
  let retrying =
    List.map state.retrying ~f:(fun row ->
      Vdom.Node.tr
        [ Vdom.Node.td [ issue_button ~select row.issue_identifier ]
        ; td (Int.to_string row.attempt)
        ; td [%string "%{(row.due_in_ms + 999) / 1000#Int}s"]
        ; td (option_text row.error)
        ])
  in
  let blocked =
    List.map state.blocked ~f:(fun row ->
      Vdom.Node.tr
        [ Vdom.Node.td [ issue_button ~select row.issue_identifier ]
        ; td (option_text row.state)
        ; td (option_text row.error)
        ])
  in
  Vdom.Node.main
    [ Vdom.Node.header
        [ Vdom.Node.h1 [ text "Maestro" ]
        ; Vdom.Node.p
            ~attrs:[ Vdom.Attr.class_ "muted" ]
            [ text (Time_ns.to_string_utc state.generated_at) ]
        ; Vdom.Node.div
            ~attrs:[ Vdom.Attr.class_ "totals" ]
            [ text [%string "agents %{state.counts.running#Int}"]
            ; text [%string "backoff %{state.counts.retrying#Int}"]
            ; text [%string "blocked %{state.counts.blocked#Int}"]
            ; text
                [%string
                  "tokens in %{commas state.codex_totals.input_tokens} / out %{commas \
                   state.codex_totals.output_tokens}"]
            ; text [%string "runtime %{seconds state.codex_totals.seconds_running}"]
            ]
        ]
    ; Vdom.Node.div
        ~attrs:[ Vdom.Attr.class_ "layout" ]
        [ Vdom.Node.div
            [ table
                ~title:"Running"
                ~headers:[ "ID"; "STATE"; "TURN"; "TOKENS"; "EVENT" ]
                running
            ; table
                ~title:"Backoff queue"
                ~headers:[ "ID"; "ATTEMPT"; "IN"; "ERROR" ]
                retrying
            ; table ~title:"Blocked" ~headers:[ "ID"; "STATE"; "ERROR" ] blocked
            ]
        ; detail_view selected detail
        ]
    ]
;;

let component state ~fetch_detail (local_ graph) =
  let selected, set_selected = Bonsai.state None graph in
  let detail, set_detail = Bonsai.state None graph in
  let open Bonsai.Let_syntax in
  let%arr state and selected and set_selected and detail and set_detail in
  let select identifier =
    let%bind.Effect () = set_selected (Some identifier) in
    let%bind.Effect () = set_detail None in
    let%bind.Effect detail = fetch_detail identifier in
    set_detail (Some detail)
  in
  view state ~selected ~detail ~select
;;
