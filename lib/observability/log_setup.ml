open! Core
open! Async

let log_relative_path = "log/maestro.log"

let rotation =
  Log.Rotation.create
    ~size:(Byte_units.of_megabytes 10.)
    ~keep:(`At_least 5)
    ~naming_scheme:`Numbered
    ()
;;

let configure ~logs_root =
  let path = Filename.concat logs_root log_relative_path in
  let%map () = Unix.mkdir ~p:() (Filename.dirname path) in
  (* [basename] omits the ".log" suffix, which [rotating_file] appends. *)
  let basename = Option.value (String.chop_suffix path ~suffix:".log") ~default:path in
  Log.Global.set_output [ Log.Output.rotating_file `Sexp ~basename rotation ];
  Log.Global.set_level `Info
;;

let configure_stderr () =
  Log.Global.set_output [ Log.Output.stderr () ];
  Log.Global.set_level `Info
;;
