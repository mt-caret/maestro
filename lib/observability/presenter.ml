open! Core
open! Jsonaf.Export
open Maestro_orchestrator
module Http_api = Maestro_snapshot.Http_api

let time t = `String (Time_ns.to_string_iso8601_basic t ~zone:Time_float.Zone.utc)

let state_payload (snapshot : Snapshot.t) ~generated_at =
  Http_api.State.jsonaf_of_t
    { generated_at
    ; counts =
        { running = List.length snapshot.running
        ; retrying = List.length snapshot.retrying
        ; blocked = List.length snapshot.blocked
        }
    ; running = snapshot.running
    ; retrying = snapshot.retrying
    ; blocked = snapshot.blocked
    ; codex_totals = snapshot.codex_totals
    ; rate_limits = snapshot.rate_limits
    }
;;

let issue_payload (snapshot : Snapshot.t) ~issue_identifier =
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
      (Http_api.Detail.jsonaf_of_t
         { issue_identifier
         ; issue_id
         ; status
         ; running
         ; retry = retrying
         ; blocked
         ; last_error =
             Option.first_some
               (Option.bind blocked ~f:(fun b -> b.error))
               (Option.bind retrying ~f:(fun r -> r.error))
         })
;;

let refresh_response ~queued ~coalesced ~requested_at =
  `Object
    [ ("queued", if queued then `True else `False)
    ; ("coalesced", if coalesced then `True else `False)
    ; "requested_at", time requested_at
    ; "operations", `Array [ `String "poll"; `String "reconcile" ]
    ]
;;
