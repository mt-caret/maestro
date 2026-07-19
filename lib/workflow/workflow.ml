open! Core
open! Async

module Loaded = struct
  type t =
    { config : Config.t
    ; prompt_template : string
    ; front_matter : Jsonaf.t
    }
  [@@deriving sexp_of]
end

let rec yaml_to_jsonaf (yaml : Yaml.value) : Jsonaf.t =
  match yaml with
  | `Null -> `Null
  | `Bool true -> `True
  | `Bool false -> `False
  | `Float f ->
    (* YAML integers surface as floats; render integral values as plain integers so the
       typed config layer can parse them strictly. *)
    let literal =
      match Float.is_integer f && Float.( <= ) (Float.abs f) 1e15 with
      | true -> Int.to_string (Float.to_int f)
      | false -> Float.to_string f
    in
    `Number literal
  | `String s -> `String s
  | `A elements -> `Array (List.map elements ~f:yaml_to_jsonaf)
  | `O fields -> `Object (List.map fields ~f:(fun (name, v) -> name, yaml_to_jsonaf v))
;;

let split_front_matter contents =
  match String.split_lines contents with
  | "---" :: rest ->
    let front_matter_lines, rest =
      List.split_while rest ~f:(fun line -> not (String.equal line "---"))
    in
    let prompt_lines =
      match rest with
      | "---" :: prompt -> prompt
      | _ ->
        (* Unterminated front matter: accepted, with an empty prompt (ref behavior). *)
        []
    in
    String.concat front_matter_lines ~sep:"\n", prompt_lines
  | lines -> "", lines
;;

let parse_front_matter front_matter_text =
  match String.is_empty (String.strip front_matter_text) with
  | true -> Ok (`Object [])
  | false ->
    (match Yaml.of_string front_matter_text with
     | Error (`Msg message) -> Or_error.error_s [%message "workflow_parse_error" message]
     | Ok yaml ->
       (match yaml_to_jsonaf yaml with
        | `Object _ as front_matter -> Ok front_matter
        | `Null | `True | `False | `String _ | `Number _ | `Array _ ->
          Or_error.error_s [%message "workflow_front_matter_not_a_map"]))
;;

let parse_contents contents ~workflow_dir ~getenv =
  let front_matter_text, prompt_lines = split_front_matter contents in
  let%bind.Or_error front_matter = parse_front_matter front_matter_text in
  let%map.Or_error config = Config.of_front_matter front_matter ~workflow_dir ~getenv in
  { Loaded.config
  ; prompt_template = String.strip (String.concat prompt_lines ~sep:"\n")
  ; front_matter
  }
;;

(* Reduce a file-read exception to a compact, stable reason (no monitor backtraces). *)
let read_failure_reason exn =
  match Monitor.extract_exn exn with
  | Unix.Unix_error (code, syscall, (_ : string)) ->
    [%string "%{Unix.Error.message code} (%{syscall})"]
  | exn -> Exn.to_string exn
;;

let load ~path ~getenv =
  match%map Monitor.try_with ~run:`Schedule (fun () -> Reader.file_contents path) with
  | Error exn ->
    Or_error.error_s
      [%message "missing_workflow_file" ~path ~reason:(read_failure_reason exn : string)]
  | Ok contents -> parse_contents contents ~workflow_dir:(Filename.dirname path) ~getenv
;;
