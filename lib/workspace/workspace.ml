open! Core
open! Async
open Maestro_workflow

let key ~identifier =
  let sanitized =
    String.map identifier ~f:(fun c ->
      match
        Char.is_alphanum c || Char.equal c '.' || Char.equal c '_' || Char.equal c '-'
      with
      | true -> c
      | false -> '_')
  in
  match String.equal sanitized identifier with
  | true -> identifier
  | false ->
    let hash = String.prefix (Sha256.to_hex (Sha256.string identifier)) 16 in
    [%string "%{sanitized}--%{hash}"]
;;

let path ~root ~identifier = Filename.concat root (key ~identifier)

module Created = struct
  type t =
    { path : string
    ; created_now : bool
    }
  [@@deriving sexp_of]
end

let rm_rf target =
  match%map
    Monitor.try_with ~run:`Schedule (fun () ->
      Process.run ~prog:"rm" ~args:[ "-rf"; "--"; target ] ())
  with
  | Ok (Ok (_ : string)) -> Ok ()
  | Ok (Error error) -> Error (Error.tag error ~tag:"failed to remove workspace")
  | Error exn -> Or_error.of_exn (Monitor.extract_exn exn)
;;

let validated_path ~(config : Config.t) ~identifier =
  Path_safety.validate_workspace_path
    ~workspace:(path ~root:config.workspace.root ~identifier)
    ~root:config.workspace.root
;;

let create_for_issue ~(config : Config.t) ~identifier =
  let%bind.Deferred.Or_error workspace = validated_path ~config ~identifier in
  let%bind.Deferred.Or_error created_now =
    match%bind Sys.file_exists_exn workspace with
    | true ->
      (match%bind Sys.is_directory_exn workspace with
       | true -> Deferred.Or_error.return false
       | false ->
         (* Non-directory debris at the workspace path is replaced. *)
         let%bind.Deferred.Or_error () = rm_rf workspace in
         let%map.Deferred.Or_error () = Deferred.ok (Unix.mkdir ~p:() workspace) in
         true)
    | false ->
      let%map.Deferred.Or_error () = Deferred.ok (Unix.mkdir ~p:() workspace) in
      true
  in
  match created_now, config.hooks.after_create with
  | false, _ | true, None ->
    Deferred.Or_error.return { Created.path = workspace; created_now }
  | true, Some script ->
    (match%bind
       Hook.run ~name:"after_create" ~script ~workspace ~timeout:config.hooks.timeout
     with
     | Ok () -> Deferred.Or_error.return { Created.path = workspace; created_now }
     | Error error ->
       (* A failed after_create removes the partially prepared directory so a later
          attempt re-creates (and re-hooks) it instead of silently reusing a
          half-initialized workspace. *)
       let%map (_ : unit Or_error.t) = rm_rf workspace in
       Error error)
;;

let remove_for_issue ~(config : Config.t) ~identifier =
  let%bind.Deferred.Or_error workspace = validated_path ~config ~identifier in
  match%bind Sys.file_exists_exn workspace with
  | false -> Deferred.Or_error.return ()
  | true ->
    let%bind () =
      match config.hooks.before_remove with
      | None -> return ()
      | Some script ->
        (match%bind Sys.is_directory_exn workspace with
         | false -> return ()
         | true ->
           Hook.run_best_effort
             ~name:"before_remove"
             ~script
             ~workspace
             ~timeout:config.hooks.timeout)
    in
    rm_rf workspace
;;
