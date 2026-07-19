open! Core
open! Async

module Stamp = struct
  type t =
    { mtime : Time_ns.t
    ; size : int64
    ; digest : string
    }
  [@@deriving equal, sexp_of]
end

type t =
  { path : string
  ; getenv : string -> string option
  ; sequencer : unit Throttle.Sequencer.t
  ; mutable current : Workflow.Loaded.t
  ; mutable stamp : Stamp.t option
  ; stop : unit Ivar.t
  }

let read_stamped path =
  match%map
    Monitor.try_with ~run:`Schedule (fun () ->
      let%bind stats = Unix.stat path in
      let%map contents = Reader.file_contents path in
      let stamp =
        { Stamp.mtime = Time_ns.of_time_float_round_nearest (Unix.Stats.mtime stats)
        ; size = Unix.Stats.size stats
        ; digest = Md5.to_hex (Md5.digest_string contents)
        }
      in
      contents, stamp)
  with
  | Ok result -> Ok result
  | Error exn ->
    Or_error.error_s
      [%message
        "missing_workflow_file" ~path ~reason:(Workflow.read_failure_reason exn : string)]
;;

(* Runs inside the sequencer: at most one reload check at a time, so a poll tick and a
   read racing each other cannot double-parse or interleave state updates. *)
let check_for_reload_locked t =
  match%map
    match%bind read_stamped t.path with
    | Error _ as error -> return error
    | Ok (contents, stamp) ->
      (match [%equal: Stamp.t option] (Some stamp) t.stamp with
       | true -> return (Ok `Unchanged)
       | false ->
         let%map loaded =
           Deferred.return
             (Workflow.parse_contents
                contents
                ~workflow_dir:(Filename.dirname t.path)
                ~getenv:t.getenv)
         in
         Or_error.map loaded ~f:(fun loaded -> `Reloaded (loaded, stamp)))
  with
  | Ok `Unchanged -> Ok ()
  | Ok (`Reloaded (loaded, stamp)) ->
    t.current <- loaded;
    t.stamp <- Some stamp;
    Ok ()
  | Error error ->
    [%log.error
      "failed to reload workflow; keeping last known good configuration"
        ~path:t.path
        ~_:(error : Error.t)];
    Error error
;;

let check_for_reload t =
  Throttle.enqueue t.sequencer (fun () -> check_for_reload_locked t)
;;

let create ~path ~getenv =
  match%bind Workflow.load ~path ~getenv with
  | Error _ as error -> return error
  | Ok current ->
    let t =
      { path
      ; getenv
      ; sequencer = Throttle.Sequencer.create ~continue_on_error:true ()
      ; current
      ; stamp = None
      ; stop = Ivar.create ()
      }
    in
    (* Establish the initial stamp so the first change check has a baseline. *)
    let%map (_ : unit Or_error.t) = check_for_reload t in
    Clock_ns.every'
      ~stop:(Ivar.read t.stop)
      ~continue_on_error:false
      (Time_ns.Span.of_int_ms 1_000)
      (fun () ->
         match%map check_for_reload t with
         | Ok () | Error (_ : Error.t) -> ());
    Ok t
;;

let current t =
  let%map (_ : unit Or_error.t) = check_for_reload t in
  t.current
;;

let force_reload t =
  match%map check_for_reload t with
  | Ok () -> Ok t.current
  | Error _ as error -> error
;;

let close t = Ivar.fill_if_empty t.stop ()
