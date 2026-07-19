open! Core
open Maestro_workflow
open Maestro_tracker

let priority_rank = function
  | Some priority when priority >= 1 && priority <= 4 -> priority
  | Some _ | None -> 5
;;

let created_at_key (issue : Issue.t) =
  match issue.created_at with
  | Some time -> Time_ns.to_int_ns_since_epoch time
  | None -> Int.max_value
;;

let sort_for_dispatch issues =
  List.stable_sort issues ~compare:(fun (a : Issue.t) b ->
    let by_priority = Int.compare (priority_rank a.priority) (priority_rank b.priority) in
    match by_priority with
    | 0 ->
      let by_created = Int.compare (created_at_key a) (created_at_key b) in
      (match by_created with
       | 0 -> String.compare a.identifier b.identifier
       | c -> c)
    | c -> c)
;;

let normalized_set states =
  List.map states ~f:Config.normalize_state_name |> String.Set.of_list
;;

let is_candidate (config : Config.t) (issue : Issue.t) =
  let non_blank s = not (String.is_empty (String.strip s)) in
  let active = normalized_set (Option.value config.tracker.active_states ~default:[]) in
  let terminal =
    normalized_set (Option.value config.tracker.terminal_states ~default:[])
  in
  let state = Config.normalize_state_name issue.state in
  non_blank issue.id
  && non_blank issue.identifier
  && non_blank issue.title
  && non_blank issue.state
  && Set.mem active state
  && (not (Set.mem terminal state))
  && Issue.routable issue ~required_labels:config.tracker.required_labels
;;

let available_global_slots ~(config : Config.t) ~running_count =
  Int.max (config.agent.max_concurrent_agents - running_count) 0
;;

let state_slot_available ~config ~state ~running_states =
  let limit = Config.max_concurrent_agents_for_state config ~state in
  let running_in_state =
    let target = Config.normalize_state_name state in
    List.count running_states ~f:(fun s ->
      String.equal (Config.normalize_state_name s) target)
  in
  running_in_state < limit
;;

let continuation_delay = Time_ns.Span.of_int_ms 1_000

let failure_backoff ~attempt ~cap =
  let exponent = Int.min (attempt - 1) 10 in
  let base = Time_ns.Span.of_int_ms (10_000 * Int.pow 2 exponent) in
  Time_ns.Span.min base cap
;;
