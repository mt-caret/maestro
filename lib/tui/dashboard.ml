open! Core
open Bonsai_term
module Color = Attr.Color.Expert

module Model = struct
  type t =
    { snapshot : Maestro_orchestrator.Snapshot.t
    ; selected : int
    ; dashboard_url : string option
    }
end

let selectable_count (model : Model.t) = List.length model.snapshot.running
let text ?(attrs = []) s = View.text ~attrs s
let dim s = text ~attrs:[ Attr.fg Color.lightblack ] s
let label s = text ~attrs:[ Attr.bold ] s
let commas n = Int.to_string_hum n ~delimiter:','

(* Fit [s] to exactly [width] columns: truncate with an ellipsis or right-pad. *)
let fit width s =
  let len = String.length s in
  if len = width
  then s
  else if len > width
  then if width <= 1 then String.prefix s width else String.prefix s (width - 1) ^ "…"
  else s ^ String.make (width - len) ' '
;;

let seconds_to_hms seconds =
  let seconds = Int.of_float seconds in
  let minutes = seconds / 60 in
  [%string "%{minutes#Int}m %{seconds % 60#Int}s"]
;;

(* Every left-column row is padded to this width so the detail column always starts at the
   same offset regardless of row contents. *)
let left_width = 54
let left_row ?(attrs = []) s = text ~attrs (fit left_width s)

let header (model : Model.t) =
  let { Maestro_orchestrator.Snapshot.codex_totals
      ; polling
      ; running
      ; retrying
      ; blocked
      ; _
      }
    =
    model.snapshot
  in
  let next_poll =
    match polling.next_poll_in_ms with
    | Some ms -> [%string "%{(ms + 999) / 1000#Int}s"]
    | None -> "checking…"
  in
  let counts =
    [%string
      "agents %{List.length running#Int}  backoff %{List.length retrying#Int}  blocked \
       %{List.length blocked#Int}"]
  in
  let tokens =
    [%string
      "in %{commas codex_totals.input_tokens}  out %{commas codex_totals.output_tokens}"]
  in
  let runtime = seconds_to_hms codex_totals.seconds_running in
  View.vcat
    [ View.hcat [ label "MAESTRO  "; dim counts ]
    ; View.hcat
        [ label "tokens "
        ; text ~attrs:[ Attr.fg Color.yellow ] tokens
        ; dim [%string "   runtime %{runtime}   poll in %{next_poll}"]
        ]
    ; (match model.dashboard_url with
       | Some url ->
         View.hcat [ label "dashboard "; text ~attrs:[ Attr.fg Color.cyan ] url ]
       | None -> View.none)
    ]
;;

let running_pane (model : Model.t) ~selected =
  let rows = model.snapshot.running in
  let header_row =
    left_row
      ~attrs:[ Attr.fg Color.lightblack ]
      (String.concat
         [ "  "; fit 10 "ID"; fit 12 "STATE"; fit 5 "TURN"; fit 10 "TOKENS"; "EVENT" ])
  in
  let body =
    match rows with
    | [] -> [ left_row ~attrs:[ Attr.fg Color.lightblack ] "  no active agents" ]
    | rows ->
      List.mapi rows ~f:(fun index row ->
        let marker = if index = selected then "▸ " else "  " in
        let cells =
          String.concat
            [ fit 10 row.issue_identifier
            ; fit 12 row.state
            ; fit 5 (Int.to_string row.turn_count)
            ; fit 10 (commas row.tokens.total_tokens)
            ; Option.value row.last_message ~default:""
            ]
        in
        let attrs = if index = selected then [ Attr.bold ] else [] in
        left_row ~attrs (marker ^ cells))
  in
  View.vcat (left_row ~attrs:[ Attr.bold ] "Running" :: header_row :: body)
;;

let backoff_pane (model : Model.t) =
  let rows =
    match model.snapshot.retrying with
    | [] -> [ left_row ~attrs:[ Attr.fg Color.lightblack ] "  no queued retries" ]
    | rows ->
      List.map rows ~f:(fun row ->
        let in_s = [%string "%{(row.due_in_ms + 999) / 1000#Int}s"] in
        left_row
          [%string
            "  ↻ %{fit 10 row.issue_identifier} attempt=%{row.attempt#Int} in %{in_s}  \
             %{Option.value row.error ~default:\"\"}"])
  in
  View.vcat (left_row ~attrs:[ Attr.bold ] "Backoff queue" :: rows)
;;

let blocked_pane (model : Model.t) =
  match model.snapshot.blocked with
  | [] -> View.none
  | rows ->
    View.vcat
      (left_row ~attrs:[ Attr.bold ] "Blocked"
       :: List.map rows ~f:(fun row ->
         left_row
           [%string
             "  ● %{fit 10 row.issue_identifier} %{Option.value row.error ~default:\"\"}"])
      )
;;

let detail_pane (model : Model.t) ~selected =
  match List.nth model.snapshot.running selected with
  | None -> View.vcat [ label "Detail"; dim "  select a running agent" ]
  | Some row ->
    let line l v = View.hcat [ dim (fit 10 l); text v ] in
    View.vcat
      [ label [%string "Detail: %{row.issue_identifier}"]
      ; line "state" row.state
      ; line "session" (Option.value row.session_id ~default:"–")
      ; line "turn" (Int.to_string row.turn_count)
      ; line
          "tokens"
          [%string
            "in %{commas row.tokens.input_tokens} / out %{commas \
             row.tokens.output_tokens}"]
      ; line "runtime" (seconds_to_hms row.runtime_seconds)
      ; line "workspace" (Option.value row.workspace_path ~default:"–")
      ; line "last" (Option.value row.last_message ~default:"–")
      ]
;;

let footer = dim "↑↓ select · r refresh · q quit"

let view (model : Model.t) ~dimensions:(_ : Dimensions.t) =
  let selected =
    let count = selectable_count model in
    if count = 0 then 0 else Int.clamp_exn model.selected ~min:0 ~max:(count - 1)
  in
  View.vcat
    [ header model
    ; View.none
    ; View.hcat
        [ View.vcat
            [ running_pane model ~selected
            ; View.none
            ; backoff_pane model
            ; blocked_pane model
            ]
        ; text "    "
        ; detail_pane model ~selected
        ]
    ; View.none
    ; footer
    ]
;;
