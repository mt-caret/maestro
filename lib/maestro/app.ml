open! Core
open! Async
open Maestro_workflow
open Maestro_observability

let dashboard_url ~host ~port = [%string "http://%{host}:%{port#Int}/"]

let maybe_start_http ~(config : Config.t) ~port_override ~driver =
  let port =
    match port_override with
    | Some _ as port -> port
    | None -> config.server.port
  in
  match port with
  | None -> return (Ok (None, None))
  | Some port ->
    let host = config.server.host in
    (match%map
       Maestro_http.Http_server.start
         ~host
         ~port
         ~snapshot:(fun () -> Driver.snapshot driver)
         ~request_refresh:(fun () -> Driver.request_refresh driver)
     with
     | Error _ as error -> error
     | Ok server ->
       let url = dashboard_url ~host ~port:(Maestro_http.Http_server.bound_port server) in
       [%log.info "http server listening" ~url];
       Ok (Some server, Some url))
;;

let wait_for_shutdown () =
  let shutdown = Ivar.create () in
  List.iter [ Signal.int; Signal.term ] ~f:(fun signal ->
    Signal.handle [ signal ] ~f:(fun (_ : Signal.t) -> Ivar.fill_if_empty shutdown ()));
  Ivar.read shutdown
;;

let run ~workflow_path ~logs_root ~port ?(memory_issues = fun () -> []) () =
  let%bind is_tty = Unix.isatty (Fd.stdin ()) in
  (* Interactive terminals get the dashboard and a file log; headless runs log to stderr. *)
  let%bind () =
    match is_tty with
    | true -> Log_setup.configure ~logs_root
    | false ->
      Log_setup.configure_stderr ();
      return ()
  in
  (* Resolve the workflow path to absolute so a relative workspace.root (which resolves
     against the WORKFLOW.md directory) normalizes to an absolute path before use, as SPEC
     §5.3.3 requires. *)
  let%bind workflow_path =
    match Filename.is_absolute workflow_path with
    | true -> return workflow_path
    | false ->
      let%map cwd = Unix.getcwd () in
      Filename.concat cwd workflow_path
  in
  match%bind Workflow_store.create ~path:workflow_path ~getenv:Sys.getenv with
  | Error _ as error -> return error
  | Ok workflow_store ->
    let%bind workflow = Workflow_store.current workflow_store in
    let config = workflow.config in
    let make_adapter tracker = Adapter_registry.build ~memory_issues tracker in
    (match%bind Driver.start ~workflow_store ~make_adapter with
     | Error _ as error -> return error
     | Ok driver ->
       (match%bind maybe_start_http ~config ~port_override:port ~driver with
        | Error _ as error -> return error
        | Ok (http_server, url) ->
          let shutdown () =
            let%bind () = Driver.close driver in
            let%map () =
              match http_server with
              | Some server -> Maestro_http.Http_server.close server
              | None -> return ()
            in
            Workflow_store.close workflow_store
          in
          (match is_tty && config.observability.dashboard_enabled with
           | true ->
             let%bind result =
               Maestro_tui.Tui.run
                 ~snapshot:(fun () -> Driver.snapshot driver)
                 ~request_refresh:(fun () ->
                   Driver.request_refresh driver >>| (ignore : _ -> unit))
                 ~dashboard_url:url
                 ~refresh:config.observability.refresh
             in
             let%map () = shutdown () in
             result
           | false ->
             [%log.info "running headless; press Ctrl-C to stop"];
             let%bind () = wait_for_shutdown () in
             let%map () = shutdown () in
             Ok ())))
;;
