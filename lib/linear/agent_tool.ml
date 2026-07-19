open! Core
open! Async
open Maestro_tracker

let name = "linear_graphql"

let spec : Jsonaf.t =
  `Object
    [ "name", `String name
    ; ( "description"
      , `String
          "Execute a raw GraphQL query or mutation against Linear using Symphony's \
           configured auth.\n" )
    ; ( "inputSchema"
      , `Object
          [ "type", `String "object"
          ; "additionalProperties", `False
          ; "required", `Array [ `String "query" ]
          ; ( "properties"
            , `Object
                [ ( "query"
                  , `Object
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "GraphQL query or mutation document to execute against \
                             Linear." )
                      ] )
                ; ( "variables"
                  , `Object
                      [ "type", `Array [ `String "object"; `String "null" ]
                      ; "description", `String "Optional GraphQL variables object."
                      ; "additionalProperties", `True
                      ] )
                ] )
          ] )
    ]
;;

let parse_arguments (arguments : Jsonaf.t) =
  let non_blank_query query =
    let query = String.strip query in
    match String.is_empty query with
    | true -> Error `Missing_query
    | false -> Ok (query, `Null)
  in
  match arguments with
  | `String query -> non_blank_query query
  | `Object fields ->
    (match List.Assoc.find fields "query" ~equal:String.equal with
     | Some (`String query) ->
       (match non_blank_query query with
        | Error _ as error -> error
        | Ok (query, (_ : Jsonaf.t)) ->
          (match List.Assoc.find fields "variables" ~equal:String.equal with
           | None | Some `Null -> Ok (query, `Null)
           | Some (`Object _ as variables) -> Ok (query, variables)
           | Some (`True | `False | `String _ | `Number _ | `Array _) ->
             Error `Invalid_variables))
     | Some (`Null | `True | `False | `Number _ | `Array _ | `Object _) | None ->
       Error `Missing_query)
  | `Null | `True | `False | `Number _ | `Array _ -> Error `Invalid_arguments
;;

let success_result body =
  let output = Jsonaf.to_string_hum body in
  let has_graphql_errors =
    match body with
    | `Object fields ->
      (match List.Assoc.find fields "errors" ~equal:String.equal with
       | Some (`Array (_ :: _)) -> true
       | Some (`Array [] | `Null | `True | `False | `String _ | `Number _ | `Object _)
       | None -> false)
    | `Null | `True | `False | `String _ | `Number _ | `Array _ -> false
  in
  { Adapter.Tool_result.success = not has_graphql_errors
  ; output
  ; content_items = [ `Object [ "type", `String "inputText"; "text", `String output ] ]
  }
;;

let execute ?request_fun ~settings ~name:requested_name ~arguments () =
  let fail = Adapter.Tool_result.of_error_message in
  match String.equal (String.strip requested_name) name with
  | false ->
    return
      (fail
         ~extra:[ "supportedTools", `Array [ `String name ] ]
         [%string "Unsupported dynamic tool: \"%{requested_name}\"."])
  | true ->
    (match parse_arguments arguments with
     | Error `Missing_query ->
       return (fail "`linear_graphql` requires a non-empty `query` string.")
     | Error `Invalid_arguments ->
       return
         (fail
            "`linear_graphql` expects either a GraphQL query string or an object with \
             `query` and optional `variables`.")
     | Error `Invalid_variables ->
       return (fail "`linear_graphql.variables` must be a JSON object when provided.")
     | Ok (query, variables) ->
       (match%map Client.graphql ?request_fun ~settings ~query ~variables () with
        | Ok body -> success_result body
        | Error Missing_api_token ->
          fail
            "Symphony is missing Linear auth. Set `tracker.provider.api_key` in \
             `WORKFLOW.md` or export `LINEAR_API_KEY`."
        | Error (Api_status status) ->
          fail
            ~extra:[ "status", `Number (Int.to_string status) ]
            [%string "Linear GraphQL request failed with HTTP %{status#Int}."]
        | Error (Api_request reason) ->
          fail
            ~extra:[ "reason", `String reason ]
            "Linear GraphQL request failed before receiving a successful response."
        | Error
            (( Missing_project_slug
             | Missing_viewer_identity
             | Graphql_errors _
             | Unknown_payload
             | Missing_end_cursor ) as error) ->
          fail
            ~extra:
              [ "reason", `String (Sexp.to_string [%sexp (error : Client.Client_error.t)])
              ]
            "Linear GraphQL tool execution failed."))
;;
