open! Core
open! Async

(* Bounds symlink-chase restarts; a chain deeper than this is treated as a cycle. *)
let max_symlink_restarts = 40

let split_segments path =
  String.split path ~on:'/' |> List.filter ~f:(Fn.non String.is_empty)
;;

(* Resolve [.] and [..] textually, without touching the filesystem. Used to distinguish
   "lexically inside the root but escaping via a symlink" from "plainly outside". *)
let lexically_normalize path =
  let resolved =
    List.fold (split_segments path) ~init:[] ~f:(fun acc segment ->
      match segment with
      | "." -> acc
      | ".." -> List.drop acc 1
      | segment -> segment :: acc)
  in
  "/" ^ String.concat ~sep:"/" (List.rev resolved)
;;

let canonicalize path =
  match Filename.is_absolute path with
  | false ->
    Deferred.return
      (Or_error.error_s
         [%message "path_canonicalize_failed" ~path ~reason:"path is not absolute"])
  | true ->
    (* [resolved] is a canonical, symlink-free prefix; [segments] is what remains. A
       symlink restarts the walk on the rewritten path, consuming fuel. Once a segment
       does not exist, the remaining suffix is appended verbatim (paths need not exist). *)
    let rec walk ~fuel ~resolved segments =
      match segments with
      | [] -> return (Ok resolved)
      | segment :: rest ->
        (match segment with
         | "." -> walk ~fuel ~resolved rest
         | ".." ->
           let resolved =
             match String.equal resolved "/" with
             | true -> "/"
             | false -> Filename.dirname resolved
           in
           walk ~fuel ~resolved rest
         | segment ->
           let candidate =
             match String.equal resolved "/" with
             | true -> "/" ^ segment
             | false -> [%string "%{resolved}/%{segment}"]
           in
           let append_verbatim () =
             return (Ok (List.fold rest ~init:candidate ~f:Filename.concat))
           in
           (match%bind
              Monitor.try_with ~run:`Schedule (fun () -> Unix.lstat candidate)
            with
            | Error exn ->
              (match Monitor.extract_exn exn with
               | Unix.Unix_error (ENOENT, (_ : string), (_ : string)) ->
                 append_verbatim ()
               | exn ->
                 return
                   (Or_error.error_s
                      [%message
                        "path_canonicalize_failed"
                          ~path
                          ~at:candidate
                          ~reason:(Exn.to_string exn : string)]))
            | Ok stats ->
              (match Unix.Stats.kind stats with
               | `Link ->
                 (match fuel <= 0 with
                  | true ->
                    return
                      (Or_error.error_s
                         [%message
                           "path_canonicalize_failed"
                             ~path
                             ~at:candidate
                             ~reason:"too many levels of symbolic links"])
                  | false ->
                    let%bind target = Unix.readlink candidate in
                    let restarted =
                      let base =
                        match Filename.is_absolute target with
                        | true -> target
                        | false -> Filename.concat resolved target
                      in
                      List.fold rest ~init:base ~f:Filename.concat
                    in
                    walk ~fuel:(fuel - 1) ~resolved:"/" (split_segments restarted))
               | `File | `Directory | `Char | `Block | `Fifo | `Socket ->
                 walk ~fuel ~resolved:candidate rest)))
    in
    walk ~fuel:max_symlink_restarts ~resolved:"/" (split_segments path)
;;

let validate_workspace_path ~workspace ~root =
  let%bind.Deferred.Or_error canonical_workspace = canonicalize workspace in
  let%bind.Deferred.Or_error canonical_root = canonicalize root in
  match String.equal canonical_workspace canonical_root with
  | true ->
    Deferred.return
      (Or_error.error_s
         [%message
           "workspace_equals_root" ~workspace:canonical_workspace ~root:canonical_root])
  | false ->
    (match
       String.is_prefix (canonical_workspace ^ "/") ~prefix:(canonical_root ^ "/")
     with
     | true -> Deferred.Or_error.return canonical_workspace
     | false ->
       (* Lexically inside the root but canonically outside means a symlink escaped. *)
       (match
          String.is_prefix
            (lexically_normalize workspace ^ "/")
            ~prefix:(lexically_normalize root ^ "/")
        with
        | true ->
          Deferred.return
            (Or_error.error_s
               [%message "workspace_symlink_escape" ~workspace ~root:canonical_root])
        | false ->
          Deferred.return
            (Or_error.error_s
               [%message
                 "workspace_outside_root"
                   ~workspace:canonical_workspace
                   ~root:canonical_root])))
;;
