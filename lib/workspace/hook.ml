open! Core
open! Async

let truncate_for_log output =
  match String.length output > 2_048 with
  | true -> String.prefix output 2_048 ^ "... (truncated)"
  | false -> output
;;

let run ~name ~script ~workspace ~timeout =
  [%log.debug "running workspace hook" ~hook:name ~workspace];
  match%bind
    Monitor.try_with ~run:`Schedule (fun () ->
      Process.create_exn ~prog:"sh" ~args:[ "-lc"; script ] ~working_dir:workspace ())
  with
  | Error exn ->
    Deferred.return
      (Or_error.error_s
         [%message
           "workspace_hook_failed"
             ~hook:name
             ~reason:(Exn.to_string (Monitor.extract_exn exn) : string)])
  | Ok process ->
    (match%bind
       Clock_ns.with_timeout timeout (Process.collect_output_and_wait process)
     with
     | `Timeout ->
       (* The wait is bounded; make sure the hook process dies too. *)
       Signal_unix.send_i Signal.kill (`Pid (Process.pid process));
       Deferred.return
         (Or_error.error_s
            [%message "workspace_hook_timeout" ~hook:name (timeout : Time_ns.Span.t)])
     | `Result output ->
       let%tydi { Process.Output.stdout; stderr; exit_status } = output in
       let combined_output = stdout ^ stderr in
       (match exit_status with
        | Ok () -> Deferred.Or_error.return ()
        | Error status ->
          [%log.info
            "workspace hook failed"
              ~hook:name
              ~workspace
              ~status:(Unix.Exit_or_signal.to_string_hum (Error status) : string)
              ~output:(truncate_for_log combined_output : string)];
          Deferred.return
            (Or_error.error_s
               [%message
                 "workspace_hook_failed"
                   ~hook:name
                   ~status:(Unix.Exit_or_signal.to_string_hum (Error status) : string)
                   ~output:combined_output])))
;;

let run_best_effort ~name ~script ~workspace ~timeout =
  match%map run ~name ~script ~workspace ~timeout with
  | Ok () -> ()
  | Error error ->
    [%log.info
      "ignoring workspace hook failure" ~hook:name ~workspace ~_:(error : Error.t)]
;;
