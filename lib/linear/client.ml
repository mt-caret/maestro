open! Core
open! Async
open Maestro_workflow
open Maestro_tracker

(* Minimal Jsonaf accessors; option-returning so shape mismatches normalize instead of
   raising. *)
module J = struct
  let member name = function
    | `Object fields -> List.Assoc.find fields name ~equal:String.equal
    | `Null | `True | `False | `String _ | `Number _ | `Array _ -> None
  ;;

  let string = function
    | `String s -> Some s
    | `Null | `True | `False | `Number _ | `Array _ | `Object _ -> None
  ;;

  let int = function
    | `Number s -> Option.try_with (fun () -> Int.of_string s)
    | `Null | `True | `False | `String _ | `Array _ | `Object _ -> None
  ;;

  let list = function
    | `Array elements -> Some elements
    | `Null | `True | `False | `String _ | `Number _ | `Object _ -> None
  ;;

  let bool = function
    | `True -> Some true
    | `False -> Some false
    | `Null | `String _ | `Number _ | `Array _ | `Object _ -> None
  ;;

  let member_string name value = Option.bind (member name value) ~f:string
end

let non_blank string = not (String.is_empty (String.strip string))

module Settings = struct
  type t =
    { endpoint : Jsonaf.t option
    ; api_key : (string option[@sexp.opaque])
    ; project_slug : string option
    ; assignee : string option
    ; terminal_states : string list
    }
  [@@deriving sexp_of]

  let of_tracker_config (tracker : Config.Tracker.t) =
    let find name = List.Assoc.find tracker.resolved_provider name ~equal:String.equal in
    let find_string name = Option.bind (find name) ~f:J.string in
    { endpoint = find "endpoint"
    ; api_key = find_string "api_key"
    ; project_slug = find_string "project_slug"
    ; assignee = find_string "assignee"
    ; terminal_states = Option.value tracker.terminal_states ~default:[]
    }
  ;;

  (* Checked in the reference's order; "present" means a non-blank string. *)
  let validate t =
    let { endpoint; api_key; project_slug; assignee; terminal_states = _ } = t in
    match Option.bind endpoint ~f:J.string with
    | None -> Or_error.error_s [%message "invalid_linear_endpoint"]
    | Some endpoint when not (non_blank endpoint) ->
      Or_error.error_s [%message "invalid_linear_endpoint"]
    | Some (_ : string) ->
      (match Option.exists api_key ~f:non_blank with
       | false -> Or_error.error_s [%message "missing_linear_api_token"]
       | true ->
         (match Option.exists project_slug ~f:non_blank with
          | false -> Or_error.error_s [%message "missing_linear_project_slug"]
          | true ->
            (match assignee with
             | Some assignee when not (non_blank assignee) ->
               Or_error.error_s [%message "invalid_linear_assignee"]
             | Some _ | None -> Ok ())))
  ;;
end

module Client_error = struct
  type t =
    | Missing_api_token
    | Missing_project_slug
    | Missing_viewer_identity
    | Api_status of int
    | Api_request of string
    | Graphql_errors of Jsonaf.t
    | Unknown_payload
    | Missing_end_cursor
  [@@deriving sexp_of]

  let to_error = function
    | Missing_api_token -> Error.create_s [%message "missing_linear_api_token"]
    | Missing_project_slug -> Error.create_s [%message "missing_linear_project_slug"]
    | Missing_viewer_identity ->
      Error.create_s [%message "missing_linear_viewer_identity"]
    | Api_status status -> Error.create_s [%message "linear_api_status" (status : int)]
    | Api_request reason -> Error.create_s [%message "linear_api_request" reason]
    | Graphql_errors errors ->
      Error.create_s [%message "linear_graphql_errors" (errors : Jsonaf.t)]
    | Unknown_payload -> Error.create_s [%message "linear_unknown_payload"]
    | Missing_end_cursor -> Error.create_s [%message "linear_missing_end_cursor"]
  ;;
end

module Request = struct
  type t =
    { endpoint : string
    ; headers : ((string * string) list[@sexp.opaque])
    ; body : string
    }
  [@@deriving sexp_of]
end

type request_fun = Request.t -> (int * string) Deferred.Or_error.t

let overall_request_deadline = Time_ns.Span.of_int_ms 120_000

let default_request_fun { Request.endpoint; headers; body } =
  match%map
    Clock_ns.with_timeout
      overall_request_deadline
      (Monitor.try_with ~run:`Schedule (fun () ->
         let%bind response, body =
           Cohttp_async.Client.post
             ~headers:(Cohttp.Header.of_list headers)
             ~body:(Cohttp_async.Body.of_string body)
             (Uri.of_string endpoint)
         in
         let%map body = Cohttp_async.Body.to_string body in
         Cohttp.Code.code_of_status (Cohttp.Response.status response), body))
  with
  | `Timeout -> Or_error.error_s [%message "request timed out"]
  | `Result (Ok result) -> Ok result
  | `Result (Error exn) -> Or_error.of_exn (Monitor.extract_exn exn)
;;

let summarize_for_log body =
  let collapsed =
    String.split_on_chars body ~on:[ ' '; '\t'; '\n'; '\r' ]
    |> List.filter ~f:(Fn.non String.is_empty)
    |> String.concat ~sep:" "
  in
  match String.length collapsed > 1_000 with
  | true -> String.prefix collapsed 1_000 ^ "...<truncated>"
  | false -> collapsed
;;

let graphql
  ?operation_name
  ?(request_fun = default_request_fun)
  ~settings
  ~query
  ~variables
  ()
  =
  let%tydi { Settings.endpoint
           ; api_key
           ; project_slug = _
           ; assignee = _
           ; terminal_states = _
           }
    =
    settings
  in
  match Option.filter api_key ~f:non_blank with
  | None -> return (Error Client_error.Missing_api_token)
  | Some api_key ->
    let endpoint =
      Option.bind endpoint ~f:J.string
      |> Option.value ~default:"https://api.linear.app/graphql"
    in
    let body =
      `Object
        (List.concat
           [ [ "query", `String query; "variables", variables ]
           ; (match Option.filter operation_name ~f:non_blank with
              | Some name -> [ "operationName", `String (String.strip name) ]
              | None -> [])
           ])
      |> Jsonaf.to_string
    in
    let request =
      { Request.endpoint
      ; headers =
          [ "Authorization", api_key (* Raw personal API key, no "Bearer" prefix. *)
          ; "Content-Type", "application/json"
          ]
      ; body
      }
    in
    (match%map request_fun request with
     | Error error -> Error (Client_error.Api_request (Error.to_string_hum error))
     | Ok (200, body) ->
       (match Option.try_with (fun () -> Jsonaf.of_string body) with
        | Some json -> Ok json
        | None -> Error Client_error.Unknown_payload)
     | Ok (status, body) ->
       [%log.info
         "Linear GraphQL request failed"
           (status : int)
           ~body:(summarize_for_log body : string)];
       Error (Client_error.Api_status status))
;;

let issue_page_size = 50

let issue_node_fields =
  {|id identifier title description priority state { name } branchName url
      assignee { id } labels { nodes { name } }
      inverseRelations(first: $relationFirst) { nodes { type issue { id identifier state { name } } } }
      createdAt updatedAt|}
;;

let poll_query =
  [%string
    {|query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
  issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
    nodes { %{issue_node_fields} }
    pageInfo { hasNextPage endCursor }
  }
}|}]
;;

let by_ids_query =
  [%string
    {|query SymphonyLinearIssuesById($ids: [ID!]!, $projectSlug: String!, $first: Int!, $relationFirst: Int!) {
  issues(filter: {id: {in: $ids}, project: {slugId: {eq: $projectSlug}}}, first: $first) {
    nodes { %{issue_node_fields} }
  }
}|}]
;;

let viewer_query = {|query SymphonyLinearViewer { viewer { id } }|}

module Assignee_filter = struct
  type t =
    | Everyone
    | Ids of String.Set.t

  let matches t (issue_assignee_id : string option) =
    match t with
    | Everyone -> true
    | Ids ids ->
      (match issue_assignee_id with
       | None -> false
       | Some id -> Set.mem ids id)
  ;;
end

(* [assignee: "me"] resolves through the viewer identity on every fetch call (one extra
   roundtrip per poll, as in the reference). *)
let resolve_assignee_filter ?request_fun ~settings () =
  let%tydi { Settings.assignee; _ } = settings in
  match
    Option.bind assignee ~f:(fun a -> Option.some_if (non_blank a) (String.strip a))
  with
  | None -> return (Ok Assignee_filter.Everyone)
  | Some "me" ->
    (match%map
       graphql
         ?request_fun
         ~operation_name:"SymphonyLinearViewer"
         ~settings
         ~query:viewer_query
         ~variables:(`Object [])
         ()
     with
     | Error _ as error -> error
     | Ok body ->
       (match
          J.member "data" body
          |> Option.bind ~f:(J.member "viewer")
          |> Option.bind ~f:(J.member_string "id")
        with
        | Some id -> Ok (Assignee_filter.Ids (String.Set.singleton id))
        | None -> Error Client_error.Missing_viewer_identity))
  | Some literal -> return (Ok (Assignee_filter.Ids (String.Set.singleton literal)))
;;

let normalize_blocker node =
  let issue = J.member "issue" node in
  { Issue.Blocker.id = Option.bind issue ~f:(J.member_string "id")
  ; identifier = Option.bind issue ~f:(J.member_string "identifier")
  ; state =
      Option.bind issue ~f:(J.member "state") |> Option.bind ~f:(J.member_string "name")
  }
;;

let normalize_node ~terminal_states ~assignee_filter node : Issue.t option =
  let required name = Option.filter (J.member_string name node) ~f:non_blank in
  let%bind.Option id = required "id" in
  let%bind.Option identifier = required "identifier" in
  let%bind.Option title = required "title" in
  let%map.Option state =
    J.member "state" node
    |> Option.bind ~f:(J.member_string "name")
    |> Option.filter ~f:non_blank
  in
  let labels =
    J.member "labels" node
    |> Option.bind ~f:(J.member "nodes")
    |> Option.bind ~f:J.list
    |> Option.value ~default:[]
    |> List.filter_map ~f:(J.member_string "name")
    |> List.map ~f:Config.normalize_state_name
    |> List.filter ~f:(Fn.non String.is_empty)
    |> List.stable_dedup ~compare:String.compare
  in
  let blocked_by =
    J.member "inverseRelations" node
    |> Option.bind ~f:(J.member "nodes")
    |> Option.bind ~f:J.list
    |> Option.value ~default:[]
    |> List.filter ~f:(fun relation ->
      match J.member_string "type" relation with
      | Some type_ -> String.equal (Config.normalize_state_name type_) "blocks"
      | None -> false)
    |> List.map ~f:normalize_blocker
  in
  let assignee_id = J.member "assignee" node |> Option.bind ~f:(J.member_string "id") in
  let timestamp name =
    J.member_string name node
    |> Option.bind ~f:(fun s -> Option.try_with (fun () -> Time_ns.of_string s))
  in
  let terminal_states =
    List.map terminal_states ~f:Config.normalize_state_name |> String.Set.of_list
  in
  (* Blockers gate dispatch only for Todo-state issues; a blocker with no readable state
     counts as blocking (SPEC: adapters must not invent semantics they cannot check). *)
  let blocked_before_dispatch =
    String.equal (Config.normalize_state_name state) "todo"
    && List.exists blocked_by ~f:(fun blocker ->
      match blocker.state with
      | None -> true
      | Some blocker_state ->
        not (Set.mem terminal_states (Config.normalize_state_name blocker_state)))
  in
  let dispatchable =
    Assignee_filter.matches assignee_filter assignee_id && not blocked_before_dispatch
  in
  { Issue.id
  ; native_ref = None
  ; identifier
  ; title
  ; description = J.member_string "description" node
  ; priority = Option.bind (J.member "priority" node) ~f:J.int
  ; state
  ; branch_name = J.member_string "branchName" node
  ; url = J.member_string "url" node
  ; assignee_id
  ; labels
  ; blocked_by
  ; dispatchable
  ; created_at = timestamp "createdAt"
  ; updated_at = timestamp "updatedAt"
  }
;;

let decode_issue_page body =
  match
    J.member "data" body
    |> Option.bind ~f:(J.member "issues")
    |> Option.bind ~f:(fun issues ->
      Option.map
        (Option.bind (J.member "nodes" issues) ~f:J.list)
        ~f:(fun nodes -> nodes, J.member "pageInfo" issues))
  with
  | Some (nodes, page_info) -> Ok (nodes, page_info)
  | None ->
    (match J.member "errors" body with
     | Some errors -> Error (Client_error.Graphql_errors errors)
     | None -> Error Client_error.Unknown_payload)
;;

let project_slug_or_error settings =
  let%tydi { Settings.project_slug; _ } = settings in
  match Option.filter project_slug ~f:non_blank with
  | Some slug -> Ok slug
  | None -> Error Client_error.Missing_project_slug
;;

let fetch_issues_by_states ?request_fun ~settings state_names =
  let state_names =
    List.map state_names ~f:Fn.id |> List.stable_dedup ~compare:String.compare
  in
  match state_names with
  | [] -> return (Ok [])
  | state_names ->
    (match project_slug_or_error settings with
     | Error _ as error -> return error
     | Ok project_slug ->
       (match%bind resolve_assignee_filter ?request_fun ~settings () with
        | Error _ as error -> return error
        | Ok assignee_filter ->
          let%tydi { Settings.terminal_states; _ } = settings in
          let fetch_page ~after =
            let variables =
              `Object
                (List.concat
                   [ [ "projectSlug", `String project_slug
                     ; "stateNames", `Array (List.map state_names ~f:(fun s -> `String s))
                     ; "first", `Number (Int.to_string issue_page_size)
                     ; "relationFirst", `Number (Int.to_string issue_page_size)
                     ]
                   ; (match after with
                      | Some cursor -> [ "after", `String cursor ]
                      | None -> [ "after", `Null ])
                   ])
            in
            graphql
              ?request_fun
              ~operation_name:"SymphonyLinearPoll"
              ~settings
              ~query:poll_query
              ~variables
              ()
          in
          let rec loop ~after ~accumulated_nodes =
            match%bind fetch_page ~after with
            | Error _ as error -> return error
            | Ok body ->
              (match decode_issue_page body with
               | Error _ as error -> return error
               | Ok (nodes, page_info) ->
                 let accumulated_nodes = accumulated_nodes @ nodes in
                 let has_next_page =
                   Option.bind page_info ~f:(J.member "hasNextPage")
                   |> Option.bind ~f:J.bool
                   |> Option.value ~default:false
                 in
                 (match has_next_page with
                  | false -> return (Ok accumulated_nodes)
                  | true ->
                    (match
                       Option.bind page_info ~f:(J.member_string "endCursor")
                       |> Option.filter ~f:non_blank
                     with
                     | None -> return (Error Client_error.Missing_end_cursor)
                     | Some cursor -> loop ~after:(Some cursor) ~accumulated_nodes)))
          in
          (match%map loop ~after:None ~accumulated_nodes:[] with
           | Error _ as error -> error
           | Ok nodes ->
             (* Poll path: malformed records are dropped with a warning — they were never
                safe to dispatch (SPEC §11.1). *)
             let issues =
               List.filter_map nodes ~f:(normalize_node ~terminal_states ~assignee_filter)
             in
             let dropped = List.length nodes - List.length issues in
             (match dropped > 0 with
              | true ->
                [%log.info "dropping malformed Linear issue records" (dropped : int)]
              | false -> ());
             Ok issues)))
;;

let fetch_issues_by_ids ?request_fun ~settings ids =
  let ids = List.stable_dedup ids ~compare:String.compare in
  match ids with
  | [] -> return (Ok [])
  | ids ->
    (match project_slug_or_error settings with
     | Error _ as error -> return error
     | Ok project_slug ->
       (match%bind resolve_assignee_filter ?request_fun ~settings () with
        | Error _ as error -> return error
        | Ok assignee_filter ->
          let%tydi { Settings.terminal_states; _ } = settings in
          let fetch_batch batch =
            let variables =
              `Object
                [ "ids", `Array (List.map batch ~f:(fun id -> `String id))
                ; "projectSlug", `String project_slug
                ; "first", `Number (Int.to_string (List.length batch))
                ; "relationFirst", `Number (Int.to_string issue_page_size)
                ]
            in
            match%map
              graphql
                ?request_fun
                ~operation_name:"SymphonyLinearIssuesById"
                ~settings
                ~query:by_ids_query
                ~variables
                ()
            with
            | Error _ as error -> error
            | Ok body ->
              (match decode_issue_page body with
               | Error _ as error -> error
               | Ok (nodes, (_ : Jsonaf.t option)) ->
                 (* Id-refresh path: any malformed requested record fails the whole fetch
                    — omission is meaningful here (SPEC §11.1). *)
                 let issues =
                   List.map nodes ~f:(normalize_node ~terminal_states ~assignee_filter)
                   |> Option.all
                 in
                 (match issues with
                  | Some issues -> Ok issues
                  | None -> Error Client_error.Unknown_payload))
          in
          let%map batches =
            List.chunks_of ids ~length:issue_page_size
            |> Deferred.List.map ~how:`Sequential ~f:fetch_batch
          in
          (match Result.all batches with
           | Error _ as error -> error
           | Ok issue_lists ->
             let rank =
               List.mapi ids ~f:(fun index id -> id, index) |> String.Map.of_alist_exn
             in
             Ok
               (List.concat issue_lists
                |> List.stable_sort ~compare:(fun (a : Issue.t) b ->
                  let rank_of (issue : Issue.t) =
                    Option.value (Map.find rank issue.id) ~default:Int.max_value
                  in
                  Int.compare (rank_of a) (rank_of b))))))
;;
