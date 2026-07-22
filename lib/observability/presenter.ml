open! Core
open! Jsonaf.Export
open Maestro_orchestrator

let time t = `String (Time_ns.to_string_iso8601_basic t ~zone:Time_float.Zone.utc)
let int n = `Number (Int.to_string n)

let string_or_null = function
  | Some s -> `String s
  | None -> `Null
;;

module Session_log = struct
  type t =
    { label : string
    ; path : string
    }
end

let session_log_payload (log : Session_log.t) =
  `Object [ "label", `String log.label; "path", `String log.path; "url", `Null ]
;;

let state_payload (snapshot : Snapshot.t) ~generated_at =
  `Object
    [ "generated_at", time generated_at
    ; ( "counts"
      , `Object
          [ "running", int (List.length snapshot.running)
          ; "retrying", int (List.length snapshot.retrying)
          ; "blocked", int (List.length snapshot.blocked)
          ] )
    ; "running", `Array (List.map snapshot.running ~f:[%jsonaf_of: Snapshot.Running.t])
    ; "retrying", `Array (List.map snapshot.retrying ~f:[%jsonaf_of: Snapshot.Retrying.t])
    ; "blocked", `Array (List.map snapshot.blocked ~f:[%jsonaf_of: Snapshot.Blocked.t])
    ; "codex_totals", [%jsonaf_of: Snapshot.Codex_totals.t] snapshot.codex_totals
    ; "rate_limits", Option.value snapshot.rate_limits ~default:`Null
    ]
;;

let issue_payload (snapshot : Snapshot.t) ~issue_identifier ~codex_session_logs =
  let running =
    List.find snapshot.running ~f:(fun r ->
      String.equal r.Snapshot.Running.issue_identifier issue_identifier)
  in
  let retrying =
    List.find snapshot.retrying ~f:(fun r ->
      String.equal r.Snapshot.Retrying.issue_identifier issue_identifier)
  in
  let blocked =
    List.find snapshot.blocked ~f:(fun b ->
      String.equal b.Snapshot.Blocked.issue_identifier issue_identifier)
  in
  match running, retrying, blocked with
  | None, None, None -> None
  | _ ->
    let status =
      match running, retrying, blocked with
      | Some _, _, _ -> "running"
      | None, _, Some _ -> "blocked"
      | None, Some _, None -> "retrying"
      | None, None, None -> assert false
    in
    let issue_id =
      List.find_map
        [ Option.map running ~f:(fun r -> r.issue_id)
        ; Option.map retrying ~f:(fun r -> r.issue_id)
        ; Option.map blocked ~f:(fun b -> b.issue_id)
        ]
        ~f:Fn.id
      |> Option.value ~default:issue_identifier
    in
    Some
      (`Object
        [ "issue_identifier", `String issue_identifier
        ; "issue_id", `String issue_id
        ; "status", `String status
        ; ( "running"
          , Option.value_map running ~default:`Null ~f:[%jsonaf_of: Snapshot.Running.t] )
        ; ( "retry"
          , Option.value_map retrying ~default:`Null ~f:[%jsonaf_of: Snapshot.Retrying.t]
          )
        ; ( "blocked"
          , Option.value_map blocked ~default:`Null ~f:[%jsonaf_of: Snapshot.Blocked.t] )
        ; ( "last_error"
          , string_or_null
              (Option.first_some
                 (Option.bind blocked ~f:(fun b -> b.error))
                 (Option.bind retrying ~f:(fun r -> r.error))) )
        ; ( "logs"
          , `Object
              [ ( "codex_session_logs"
                , `Array (List.map codex_session_logs ~f:session_log_payload) )
              ] )
        ; ( "recent_events"
          , `Array
              (match running, blocked with
               | Some running, _ ->
                 List.map running.recent_events ~f:[%jsonaf_of: Snapshot.Recent_event.t]
               | None, Some blocked ->
                 List.map blocked.recent_events ~f:[%jsonaf_of: Snapshot.Recent_event.t]
               | None, None -> []) )
        ])
;;

let refresh_response ~queued ~coalesced ~requested_at =
  `Object
    [ ("queued", if queued then `True else `False)
    ; ("coalesced", if coalesced then `True else `False)
    ; "requested_at", time requested_at
    ; "operations", `Array [ `String "poll"; `String "reconcile" ]
    ]
;;
