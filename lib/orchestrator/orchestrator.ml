open! Core
open! Async
open Maestro_workflow
open Maestro_tracker
open Maestro_codex
module Token = Unique_id.Int ()

module Worker_outcome = struct
  type t =
    | Completed
    | Failed of string
  [@@deriving sexp_of]
end

module Running_entry = struct
  type t =
    { identifier : string
    ; issue : Issue.t
    ; run_token : Token.t
    ; started_at : Time_ns.t
    ; retry_attempt : int
    ; workspace_path : string option
    ; session_id : string option
    ; turn_count : int
    ; last_event : Update.Event.t option
    ; last_message : string option
    ; last_timestamp : Time_ns.t option
    ; input_blocked : bool
    ; tokens : Token_accounting.Counters.t
    }
  [@@deriving sexp_of]
end

module Retry_entry = struct
  type t =
    { attempt : int
    ; due_at : Time_ns.t
    ; token : Token.t
    ; identifier : string
    ; issue_url : string option
    ; error : string option
    ; workspace_path : string option
    }
  [@@deriving sexp_of]
end

module Blocked_entry = struct
  type t =
    { identifier : string
    ; issue : Issue.t
    ; workspace_path : string option
    ; session_id : string option
    ; error : string option
    ; blocked_at : Time_ns.t
    ; last_event : Update.Event.t option
    ; last_message : string option
    ; last_timestamp : Time_ns.t option
    }
  [@@deriving sexp_of]
end

module Codex_totals = struct
  type t =
    { input : int
    ; output : int
    ; total : int
    ; seconds_running : float
    }
  [@@deriving sexp_of]

  let empty = { input = 0; output = 0; total = 0; seconds_running = 0. }
end

module Poll_state = struct
  type t =
    { checking : bool
    ; next_poll_at : Time_ns.t option
    ; tick_token : Token.t option
    }
  [@@deriving sexp_of]

  let initial = { checking = false; next_poll_at = None; tick_token = None }
end

module State = struct
  type t =
    { running : Running_entry.t String.Map.t
    ; claimed : String.Set.t
    ; blocked : Blocked_entry.t String.Map.t
    ; retry : Retry_entry.t String.Map.t
    ; completed : String.Set.t
    ; codex_totals : Codex_totals.t
    ; rate_limits : Jsonaf.t option
    ; poll : Poll_state.t
    }
  [@@deriving sexp_of]

  let create () =
    { running = String.Map.empty
    ; claimed = String.Set.empty
    ; blocked = String.Map.empty
    ; retry = String.Map.empty
    ; completed = String.Set.empty
    ; codex_totals = Codex_totals.empty
    ; rate_limits = None
    ; poll = Poll_state.initial
    }
  ;;

  let claimed t = t.claimed
  let completed t = t.completed
end

module Event = struct
  type t =
    | Tick of
        { token : Token.t option (** [None] = an immediate poke (tests / /refresh). *) }
    | Worker_runtime_info of
        { issue_id : string
        ; workspace_path : string
        }
    | Codex_update of
        { issue_id : string
        ; update : Update.t
        }
    | Worker_exited of
        { issue_id : string
        ; run_token : Token.t
        ; outcome : Worker_outcome.t
        }
    | Retry_due of
        { issue_id : string
        ; token : Token.t
        }
  [@@deriving sexp_of]
end

module Effect = struct
  type t =
    | Spawn_worker of
        { issue : Issue.t
        ; attempt : int option
        ; run_token : Token.t
        }
    | Stop_worker of { issue_id : string }
    | Schedule_retry of
        { issue_id : string
        ; delay : Time_ns.Span.t
        ; token : Token.t
        }
    | Remove_workspace of { identifier : string }
    | Schedule_tick of
        { delay : Time_ns.Span.t
        ; token : Token.t
        }
    | Notify
  [@@deriving sexp_of]
end

let runtime_seconds ~now ~started_at =
  Float.max 0. (Time_ns.Span.to_sec (Time_ns.diff now started_at))
;;

let add_runtime_totals (totals : Codex_totals.t) ~seconds =
  { totals with seconds_running = totals.seconds_running +. seconds }
;;

(* An issue is "input-blocked" when its worker is waiting on operator input the runtime
   will not supply (SPEC §10.5): the last event was an input/approval request, or the last
   message was an MCP elicitation. *)
let entry_input_blocked (entry : Running_entry.t) = entry.input_blocked

let normalized_active (config : Config.t) =
  Option.value config.tracker.active_states ~default:[]
  |> List.map ~f:Config.normalize_state_name
  |> String.Set.of_list
;;

let normalized_terminal (config : Config.t) =
  Option.value config.tracker.terminal_states ~default:[]
  |> List.map ~f:Config.normalize_state_name
  |> String.Set.of_list
;;

let running_states (state : State.t) =
  Map.data state.running |> List.map ~f:(fun entry -> entry.Running_entry.issue.state)
;;

(* --- Retry scheduling ------------------------------------------------------- *)

let schedule_retry
  (state : State.t)
  ~issue_id
  ~attempt
  ~delay
  ~now
  ~identifier
  ~issue_url
  ~error
  ~workspace_path
  =
  let token = Token.create () in
  let entry =
    { Retry_entry.attempt
    ; due_at = Time_ns.add now delay
    ; token
    ; identifier
    ; issue_url
    ; error
    ; workspace_path
    }
  in
  (* Hold the claim through backoff so the poll loop cannot re-dispatch an issue whose
     retry timer is pending; the retry is the sole re-dispatch path (SPEC §7.1). *)
  let state =
    { state with
      retry = Map.set state.retry ~key:issue_id ~data:entry
    ; claimed = Set.add state.claimed issue_id
    }
  in
  state, [ Effect.Schedule_retry { issue_id; delay; token } ]
;;

let release_claim (state : State.t) ~issue_id =
  { state with
    claimed = Set.remove state.claimed issue_id
  ; blocked = Map.remove state.blocked issue_id
  ; retry = Map.remove state.retry issue_id
  }
;;

(* --- Codex update integration ---------------------------------------------- *)

let payload_method (update : Update.t) =
  match update.payload with
  | Some (`Object fields) ->
    (match List.Assoc.find fields "method" ~equal:String.equal with
     | Some (`String method_) -> Some method_
     | _ -> None)
  | Some _ | None -> None
;;

let integrate_update (state : State.t) ~issue_id ~(update : Update.t) =
  match Map.find state.running issue_id with
  | None -> state, [] (* Unknown/no-longer-running issue: drop. *)
  | Some entry ->
    let session_id =
      match update.session_id with
      | Some _ as id -> id
      | None -> entry.session_id
    in
    let turn_count =
      match update.event, update.session_id with
      | Session_started, Some new_id
        when not ([%equal: string option] entry.session_id (Some new_id)) ->
        entry.turn_count + 1
      | _ -> entry.turn_count
    in
    let input_blocked =
      entry.input_blocked
      || (match update.event with
          | Turn_input_required | Approval_required -> true
          | _ -> false)
      ||
      match payload_method update with
      | Some "mcpServer/elicitation/request" -> true
      | _ -> false
    in
    let tokens, totals_delta =
      match Option.bind update.payload ~f:Token_accounting.absolute_usage with
      | None -> entry.tokens, { Token_accounting.Usage.input = 0; output = 0; total = 0 }
      | Some usage -> Token_accounting.Counters.apply entry.tokens usage
    in
    let rate_limits =
      match Option.bind update.payload ~f:Token_accounting.rate_limits with
      | Some _ as rl -> rl
      | None -> state.rate_limits
    in
    let entry =
      { entry with
        session_id
      ; turn_count
      ; last_event = Some update.event
      ; last_message = Some (Humanizer.summarize update)
      ; last_timestamp = Some update.timestamp
      ; input_blocked
      ; tokens
      }
    in
    let codex_totals =
      { state.codex_totals with
        input = state.codex_totals.input + totals_delta.input
      ; output = state.codex_totals.output + totals_delta.output
      ; total = state.codex_totals.total + totals_delta.total
      }
    in
    ( { state with
        running = Map.set state.running ~key:issue_id ~data:entry
      ; codex_totals
      ; rate_limits
      }
    , [] )
;;

(* --- Dispatch --------------------------------------------------------------- *)

let dispatch (state : State.t) ~(config : Config.t) ~now ~(issue : Issue.t) ~attempt =
  let run_token = Token.create () in
  let entry =
    { Running_entry.identifier = issue.identifier
    ; issue
    ; run_token
    ; started_at = now
    ; retry_attempt = Option.value attempt ~default:0
    ; workspace_path = None
    ; session_id = None
    ; turn_count = 0
    ; last_event = None
    ; last_message = None
    ; last_timestamp = None
    ; input_blocked = false
    ; tokens = Token_accounting.Counters.empty
    }
  in
  ignore (config : Config.t);
  ( { state with
      running = Map.set state.running ~key:issue.id ~data:entry
    ; claimed = Set.add state.claimed issue.id
    ; retry = Map.remove state.retry issue.id
    }
  , [ Effect.Spawn_worker { issue; attempt; run_token } ] )
;;

let should_dispatch (state : State.t) ~(config : Config.t) ~(issue : Issue.t) =
  Dispatch_policy.is_candidate config issue
  && (not (Set.mem state.claimed issue.id))
  && (not (Map.mem state.running issue.id))
  && (not (Map.mem state.blocked issue.id))
  && Dispatch_policy.available_global_slots
       ~config
       ~running_count:(Map.length state.running)
     > 0
  && Dispatch_policy.state_slot_available
       ~config
       ~state:issue.state
       ~running_states:(running_states state)
;;

(* --- Worker exit ------------------------------------------------------------ *)

let handle_worker_exit
  (state : State.t)
  ~(config : Config.t)
  ~now
  ~issue_id
  ~run_token
  ~outcome
  =
  match Map.find state.running issue_id with
  | Some entry when Token.equal entry.run_token run_token ->
    let state =
      { state with
        running = Map.remove state.running issue_id
      ; codex_totals =
          add_runtime_totals
            state.codex_totals
            ~seconds:(runtime_seconds ~now ~started_at:entry.started_at)
      }
    in
    let block error =
      let blocked_entry =
        { Blocked_entry.identifier = entry.identifier
        ; issue = entry.issue
        ; workspace_path = entry.workspace_path
        ; session_id = entry.session_id
        ; error = Some error
        ; blocked_at = now
        ; last_event = entry.last_event
        ; last_message = entry.last_message
        ; last_timestamp = entry.last_timestamp
        }
      in
      ( { state with
          blocked = Map.set state.blocked ~key:issue_id ~data:blocked_entry
        ; claimed = Set.add state.claimed issue_id
        ; retry = Map.remove state.retry issue_id
        }
      , [ Effect.Notify ] )
    in
    (match outcome, entry_input_blocked entry with
     | Worker_outcome.Completed, false ->
       (* Normal exit: keep the claim, schedule a short continuation re-check. *)
       let state = { state with completed = Set.add state.completed issue_id } in
       let state, effects =
         schedule_retry
           state
           ~issue_id
           ~attempt:1
           ~delay:Dispatch_policy.continuation_delay
           ~now
           ~identifier:entry.identifier
           ~issue_url:entry.issue.url
           ~error:None
           ~workspace_path:entry.workspace_path
       in
       state, effects @ [ Effect.Notify ]
     | Completed, true -> block "codex turn requires operator input"
     | Failed reason, true ->
       block [%string "codex turn requires operator input (%{reason})"]
     | Failed reason, false ->
       let attempt =
         match entry.retry_attempt > 0 with
         | true -> entry.retry_attempt + 1
         | false -> 1
       in
       let delay =
         Dispatch_policy.failure_backoff ~attempt ~cap:config.agent.max_retry_backoff
       in
       let state, effects =
         schedule_retry
           state
           ~issue_id
           ~attempt
           ~delay
           ~now
           ~identifier:entry.identifier
           ~issue_url:entry.issue.url
           ~error:(Some [%string "worker exited: %{reason}"])
           ~workspace_path:entry.workspace_path
       in
       state, effects @ [ Effect.Notify ])
  | Some _ | None -> state, [] (* Stale exit from a terminated worker: ignore. *)
;;

(* --- Reconciliation --------------------------------------------------------- *)

let terminate_running (state : State.t) ~now ~issue_id ~cleanup_workspace =
  match Map.find state.running issue_id with
  | None -> release_claim state ~issue_id, []
  | Some entry ->
    let state =
      { state with
        running = Map.remove state.running issue_id
      ; codex_totals =
          add_runtime_totals
            state.codex_totals
            ~seconds:(runtime_seconds ~now ~started_at:entry.started_at)
      }
    in
    let state = release_claim state ~issue_id in
    let cleanup =
      match cleanup_workspace with
      | true -> [ Effect.Remove_workspace { identifier = entry.identifier } ]
      | false -> []
    in
    state, Effect.Stop_worker { issue_id } :: cleanup
;;

let stall_timeout (config : Config.t) = config.codex.stall_timeout

let reconcile_stalled (state : State.t) ~(config : Config.t) ~now =
  match stall_timeout config with
  | None -> state, []
  | Some timeout ->
    Map.fold
      state.running
      ~init:(state, [])
      ~f:(fun ~key:issue_id ~data:entry (state, effects) ->
        (* Skip issues already terminated earlier in this fold. *)
        match Map.mem state.running issue_id with
        | false -> state, effects
        | true ->
          let since = Option.value entry.last_timestamp ~default:entry.started_at in
          let elapsed = Time_ns.diff now since in
          (match Time_ns.Span.( > ) elapsed timeout with
           | false -> state, effects
           | true ->
             let state, more =
               match entry_input_blocked entry with
               | true ->
                 (* Stalled waiting on input: block rather than retry. *)
                 let state', _ =
                   terminate_running state ~now ~issue_id ~cleanup_workspace:false
                 in
                 let blocked_entry =
                   { Blocked_entry.identifier = entry.identifier
                   ; issue = entry.issue
                   ; workspace_path = entry.workspace_path
                   ; session_id = entry.session_id
                   ; error = Some "codex requested operator input; stalled"
                   ; blocked_at = now
                   ; last_event = entry.last_event
                   ; last_message = entry.last_message
                   ; last_timestamp = entry.last_timestamp
                   }
                 in
                 ( { state' with
                     blocked = Map.set state'.blocked ~key:issue_id ~data:blocked_entry
                   ; claimed = Set.add state'.claimed issue_id
                   }
                 , [ Effect.Stop_worker { issue_id } ] )
               | false ->
                 let state, term_effects =
                   terminate_running state ~now ~issue_id ~cleanup_workspace:false
                 in
                 let attempt =
                   match entry.retry_attempt > 0 with
                   | true -> entry.retry_attempt + 1
                   | false -> 1
                 in
                 let delay =
                   Dispatch_policy.failure_backoff
                     ~attempt
                     ~cap:config.agent.max_retry_backoff
                 in
                 let state, retry_effects =
                   schedule_retry
                     state
                     ~issue_id
                     ~attempt
                     ~delay
                     ~now
                     ~identifier:entry.identifier
                     ~issue_url:entry.issue.url
                     ~error:
                       (Some
                          [%string
                            "stalled for %{Time_ns.Span.to_string_hum elapsed} without \
                             codex activity"])
                     ~workspace_path:entry.workspace_path
                 in
                 state, term_effects @ retry_effects
             in
             state, effects @ more))
;;

let reconcile_running_refresh (state : State.t) ~(config : Config.t) ~now ~refreshed =
  let active = normalized_active config in
  let terminal = normalized_terminal config in
  let refreshed_by_id =
    List.map refreshed ~f:(fun (issue : Issue.t) -> issue.id, issue)
    |> String.Map.of_alist_reduce ~f:(fun _ last -> last)
  in
  let running_ids = Map.keys state.running in
  List.fold running_ids ~init:(state, []) ~f:(fun (state, effects) issue_id ->
    match Map.find state.running issue_id with
    | None -> state, effects
    | Some entry ->
      let state', more =
        match Map.find refreshed_by_id issue_id with
        | None ->
          (* Missing from a successful refresh: no longer visible; stop, no cleanup. *)
          terminate_running state ~now ~issue_id ~cleanup_workspace:false
        | Some issue ->
          let normalized = Config.normalize_state_name issue.state in
          if Set.mem terminal normalized
          then terminate_running state ~now ~issue_id ~cleanup_workspace:true
          else if Set.mem active normalized
                  && Issue.routable issue ~required_labels:config.tracker.required_labels
          then
            (* Keep running; refresh the snapshot so per-state slot counting stays
               current. *)
            ( { state with
                running = Map.set state.running ~key:issue_id ~data:{ entry with issue }
              }
            , [] )
          else terminate_running state ~now ~issue_id ~cleanup_workspace:false
      in
      state', effects @ more)
;;

let reconcile_blocked_refresh (state : State.t) ~(config : Config.t) ~now ~refreshed =
  let active = normalized_active config in
  let terminal = normalized_terminal config in
  let refreshed_by_id =
    List.map refreshed ~f:(fun (issue : Issue.t) -> issue.id, issue)
    |> String.Map.of_alist_reduce ~f:(fun _ last -> last)
  in
  ignore (now : Time_ns.t);
  Map.fold
    state.blocked
    ~init:(state, [])
    ~f:(fun ~key:issue_id ~data:entry (state, effects) ->
      match Map.find refreshed_by_id issue_id with
      | None -> release_claim state ~issue_id, effects
      | Some issue ->
        let normalized = Config.normalize_state_name issue.state in
        if Set.mem terminal normalized
        then
          ( release_claim state ~issue_id
          , effects @ [ Effect.Remove_workspace { identifier = entry.identifier } ] )
        else if Set.mem active normalized
                && Issue.routable issue ~required_labels:config.tracker.required_labels
        then
          ( { state with
              blocked = Map.set state.blocked ~key:issue_id ~data:{ entry with issue }
            }
          , effects )
        else release_claim state ~issue_id, effects)
;;

(* --- Snapshot --------------------------------------------------------------- *)

let to_snapshot (state : State.t) ~(config : Config.t) ~now =
  let running =
    Map.data state.running
    |> List.map ~f:(fun (entry : Running_entry.t) ->
      { Snapshot.Running.issue_id = entry.issue.id
      ; issue_identifier = entry.identifier
      ; issue_url = entry.issue.url
      ; state = entry.issue.state
      ; session_id = entry.session_id
      ; turn_count = entry.turn_count
      ; last_event =
          Option.map entry.last_event ~f:(fun event ->
            Sexp.to_string [%sexp (event : Update.Event.t)])
      ; last_message = entry.last_message
      ; started_at = entry.started_at
      ; last_event_at = entry.last_timestamp
      ; workspace_path = entry.workspace_path
      ; tokens =
          { input_tokens = Token_accounting.Counters.input entry.tokens
          ; output_tokens = Token_accounting.Counters.output entry.tokens
          ; total_tokens = Token_accounting.Counters.total entry.tokens
          }
      ; runtime_seconds = runtime_seconds ~now ~started_at:entry.started_at
      })
    |> List.sort ~compare:(fun a b ->
      String.compare a.Snapshot.Running.issue_identifier b.issue_identifier)
  in
  let retrying =
    Map.to_alist state.retry
    |> List.map ~f:(fun (issue_id, (entry : Retry_entry.t)) ->
      { Snapshot.Retrying.issue_id
      ; issue_identifier = entry.identifier
      ; issue_url = entry.issue_url
      ; attempt = entry.attempt
      ; due_in_ms = Int.max 0 (Time_ns.Span.to_int_ms (Time_ns.diff entry.due_at now))
      ; error = entry.error
      ; workspace_path = entry.workspace_path
      })
    |> List.sort ~compare:(fun a b -> Int.compare a.due_in_ms b.due_in_ms)
  in
  let blocked =
    Map.to_alist state.blocked
    |> List.map ~f:(fun (issue_id, (entry : Blocked_entry.t)) ->
      { Snapshot.Blocked.issue_id
      ; issue_identifier = entry.identifier
      ; issue_url = entry.issue.url
      ; state = Some entry.issue.state
      ; session_id = entry.session_id
      ; error = entry.error
      ; blocked_at = entry.blocked_at
      ; last_event =
          Option.map entry.last_event ~f:(fun event ->
            Sexp.to_string [%sexp (event : Update.Event.t)])
      ; last_message = entry.last_message
      })
    |> List.sort ~compare:(fun a b ->
      String.compare a.Snapshot.Blocked.issue_identifier b.issue_identifier)
  in
  (* Runtime is a live aggregate: ended-session seconds plus each active session's elapsed
     time as of now (SPEC §13.5). *)
  let active_seconds =
    Map.data state.running
    |> List.sum (module Float) ~f:(fun entry ->
      runtime_seconds ~now ~started_at:entry.Running_entry.started_at)
  in
  { Snapshot.running
  ; retrying
  ; blocked
  ; codex_totals =
      { input_tokens = state.codex_totals.input
      ; output_tokens = state.codex_totals.output
      ; total_tokens = state.codex_totals.total
      ; seconds_running = state.codex_totals.seconds_running +. active_seconds
      }
  ; rate_limits = state.rate_limits
  ; polling =
      { checking = state.poll.checking
      ; next_poll_in_ms =
          Option.map state.poll.next_poll_at ~f:(fun at ->
            Int.max 0 (Time_ns.Span.to_int_ms (Time_ns.diff at now)))
      ; poll_interval_ms = Time_ns.Span.to_int_ms config.polling.interval
      }
  }
;;

(* --- Tick and retry handlers (tracker-fetching) ----------------------------- *)

let schedule_next_tick (state : State.t) ~(config : Config.t) ~now =
  let token = Token.create () in
  let delay = config.Config.polling.interval in
  ( { state with
      poll =
        { Poll_state.checking = false
        ; next_poll_at = Some (Time_ns.add now delay)
        ; tick_token = Some token
        }
    }
  , [ Effect.Schedule_tick { delay; token } ] )
;;

(* Dispatch preflight (SPEC §6.3): the caller has already confirmed the workflow file is
   currently loadable ([config_valid]); here we also require a non-empty codex command and
   an adapter that accepts its provider config, logging the specific reason on failure. *)
let preflight_ok ~(config : Config.t) ~(adapter : Adapter.t) ~config_valid =
  match config_valid with
  | false -> false
  | true ->
    (match String.is_empty (String.strip config.Config.codex.command) with
     | true ->
       [%log.error "dispatch preflight failed" ~reason:"codex.command is empty"];
       false
     | false ->
       (match adapter.validate_config () with
        | Ok () -> true
        | Error error ->
          [%log.error "dispatch preflight failed" ~_:(error : Error.t)];
          false))
;;

let handle_tick
  (state : State.t)
  ~(config : Config.t)
  ~(adapter : Adapter.t)
  ~now
  ~config_valid
  =
  (* Reconciliation is unconditional (SPEC §8.5): stall detection, then a tracker refresh
     that keeps all workers/blocked entries on fetch failure. *)
  let state, stall_effects = reconcile_stalled state ~config ~now in
  let%bind state, running_effects =
    match Map.is_empty state.running with
    | true -> return (state, [])
    | false ->
      (match%map adapter.fetch_issues_by_ids (Map.keys state.running) with
       | Error error ->
         [%log.debug "keeping running workers; refresh failed" ~_:(error : Error.t)];
         state, []
       | Ok refreshed -> reconcile_running_refresh state ~config ~now ~refreshed)
  in
  let%bind state, blocked_effects =
    match Map.is_empty state.blocked with
    | true -> return (state, [])
    | false ->
      (match%map adapter.fetch_issues_by_ids (Map.keys state.blocked) with
       | Error error ->
         [%log.debug "keeping blocked issues; refresh failed" ~_:(error : Error.t)];
         state, []
       | Ok refreshed -> reconcile_blocked_refresh state ~config ~now ~refreshed)
  in
  let reconcile_effects = stall_effects @ running_effects @ blocked_effects in
  (* Dispatch preflight (SPEC §6.3): skip new dispatch on invalid config, but keep
     reconciliation. *)
  let%map state, dispatch_effects =
    match preflight_ok ~config ~adapter ~config_valid with
    | false -> return (state, [])
    | true ->
      let active = Option.value config.tracker.active_states ~default:[] in
      (match%map adapter.fetch_issues_by_states active with
       | Error error ->
         [%log.error
           "candidate fetch failed; skipping dispatch this tick" ~_:(error : Error.t)];
         state, []
       | Ok issues ->
         Dispatch_policy.sort_for_dispatch issues
         |> List.fold ~init:(state, []) ~f:(fun (state, effects) issue ->
           match should_dispatch state ~config ~issue with
           | false -> state, effects
           | true ->
             let state, more = dispatch state ~config ~now ~issue ~attempt:None in
             state, effects @ more))
  in
  let state, tick_effects = schedule_next_tick state ~config ~now in
  state, reconcile_effects @ dispatch_effects @ tick_effects @ [ Effect.Notify ]
;;

let handle_retry_due
  (state : State.t)
  ~(config : Config.t)
  ~(adapter : Adapter.t)
  ~now
  ~issue_id
  ~token
  =
  match Map.find state.retry issue_id with
  | None -> return (state, []) (* Already fired / cancelled. *)
  | Some entry when not (Token.equal entry.token token) -> return (state, []) (* Stale. *)
  | Some entry ->
    let state = { state with retry = Map.remove state.retry issue_id } in
    let reschedule ~attempt ~error =
      let delay =
        Dispatch_policy.failure_backoff ~attempt ~cap:config.agent.max_retry_backoff
      in
      schedule_retry
        state
        ~issue_id
        ~attempt
        ~delay
        ~now
        ~identifier:entry.identifier
        ~issue_url:entry.issue_url
        ~error:(Some error)
        ~workspace_path:entry.workspace_path
    in
    (match%map adapter.fetch_issues_by_ids [ issue_id ] with
     | Error _ ->
       (* Fetch failure: keep the claim and keep retrying (SPEC §16.6). *)
       let state, effects =
         reschedule ~attempt:(entry.attempt + 1) ~error:"retry poll failed"
       in
       state, effects @ [ Effect.Notify ]
     | Ok refreshed ->
       (match
          List.find refreshed ~f:(fun (issue : Issue.t) -> String.equal issue.id issue_id)
        with
        | None -> release_claim state ~issue_id, [ Effect.Notify ]
        | Some issue ->
          let terminal = normalized_terminal config in
          if Set.mem terminal (Config.normalize_state_name issue.state)
          then
            ( release_claim state ~issue_id
            , [ Effect.Remove_workspace { identifier = issue.identifier }; Effect.Notify ]
            )
          else if Dispatch_policy.is_candidate config issue
          then (
            let slots_free =
              Dispatch_policy.available_global_slots
                ~config
                ~running_count:(Map.length state.running)
              > 0
              && Dispatch_policy.state_slot_available
                   ~config
                   ~state:issue.state
                   ~running_states:(running_states state)
            in
            match slots_free with
            | true ->
              let state, effects =
                dispatch state ~config ~now ~issue ~attempt:(Some entry.attempt)
              in
              state, effects @ [ Effect.Notify ]
            | false ->
              let state, effects =
                reschedule
                  ~attempt:(entry.attempt + 1)
                  ~error:"no available orchestrator slots"
              in
              state, effects @ [ Effect.Notify ])
          else release_claim state ~issue_id, [ Effect.Notify ]))
;;

let handle
  (state : State.t)
  ~(config : Config.t)
  ~adapter
  ~now
  ~config_valid
  (event : Event.t)
  =
  match event with
  | Tick { token } ->
    (match token, state.poll.tick_token with
     | Some token, Some current when not (Token.equal token current) ->
       return (state, []) (* Stale periodic tick. *)
     | _ -> handle_tick state ~config ~adapter ~now ~config_valid)
  | Worker_runtime_info { issue_id; workspace_path } ->
    let state =
      match Map.find state.running issue_id with
      | None -> state
      | Some entry ->
        { state with
          running =
            Map.set
              state.running
              ~key:issue_id
              ~data:{ entry with workspace_path = Some workspace_path }
        }
    in
    return (state, [])
  | Codex_update { issue_id; update } -> return (integrate_update state ~issue_id ~update)
  | Worker_exited { issue_id; run_token; outcome } ->
    return (handle_worker_exit state ~config ~now ~issue_id ~run_token ~outcome)
  | Retry_due { issue_id; token } ->
    handle_retry_due state ~config ~adapter ~now ~issue_id ~token
;;
