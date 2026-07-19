open! Core

module J = struct
  let member name = function
    | `Object fields -> List.Assoc.find fields name ~equal:String.equal
    | `Null | `True | `False | `String _ | `Number _ | `Array _ -> None
  ;;

  let path names json =
    List.fold names ~init:(Some json) ~f:(fun acc name ->
      Option.bind acc ~f:(member name))
  ;;

  let int = function
    | `Number s -> Option.try_with (fun () -> Int.of_string s)
    | `String s ->
      (* Lenient: a leading integer prefix, matching the reference's Integer.parse. *)
      let digits =
        String.strip s
        |> String.to_list
        |> List.take_while ~f:Char.is_digit
        |> String.of_char_list
      in
      Option.try_with (fun () -> Int.of_string digits)
    | `Null | `True | `False | `Array _ | `Object _ -> None
  ;;

  let string = function
    | `String s -> Some s
    | `Null | `True | `False | `Number _ | `Array _ | `Object _ -> None
  ;;
end

module Usage = struct
  type t =
    { input : int
    ; output : int
    ; total : int
    }
  [@@deriving sexp_of]
end

(* Component key precedence: snake- and camel-case names, mirroring the reference. *)
let input_keys =
  [ "input_tokens"; "prompt_tokens"; "input"; "promptTokens"; "inputTokens" ]
;;

let output_keys =
  [ "output_tokens"
  ; "completion_tokens"
  ; "output"
  ; "completion"
  ; "outputTokens"
  ; "completionTokens"
  ]
;;

let total_keys = [ "total_tokens"; "total"; "totalTokens" ]

let usage_of_map map =
  let component keys =
    List.find_map keys ~f:(fun key -> Option.bind (J.member key map) ~f:J.int)
  in
  match component input_keys, component output_keys, component total_keys with
  | None, None, None -> None
  | input, output, total ->
    Some
      { Usage.input = Option.value input ~default:0
      ; output = Option.value output ~default:0
      ; total = Option.value total ~default:0
      }
;;

let absolute_paths =
  [ [ "params"; "msg"; "payload"; "info"; "total_token_usage" ]
  ; [ "params"; "msg"; "info"; "total_token_usage" ]
  ; [ "params"; "tokenUsage"; "total" ]
  ; [ "tokenUsage"; "total" ]
  ]
;;

let absolute_usage payload =
  match
    List.find_map absolute_paths ~f:(fun path ->
      Option.bind (J.path path payload) ~f:usage_of_map)
  with
  | Some usage -> Some usage
  | None ->
    (* Fallback: only a genuine turn/completed message contributes its usage. *)
    (match J.member "method" payload |> Option.bind ~f:J.string with
     | Some "turn/completed" ->
       List.find_map
         [ [ "usage" ]; [ "params"; "usage" ] ]
         ~f:(fun path -> Option.bind (J.path path payload) ~f:usage_of_map)
     | Some _ | None -> None)
;;

let is_rate_limit_map = function
  | `Object fields ->
    let has name = List.Assoc.mem fields name ~equal:String.equal in
    (has "limit_id" || has "limit_name")
    && (has "primary" || has "secondary" || has "credits")
  | `Null | `True | `False | `String _ | `Number _ | `Array _ -> false
;;

let rec find_rate_limits json =
  match is_rate_limit_map json with
  | true -> Some json
  | false ->
    (match json with
     | `Object fields ->
       List.find_map fields ~f:(fun (_, value) -> find_rate_limits value)
     | `Array elements -> List.find_map elements ~f:find_rate_limits
     | `Null | `True | `False | `String _ | `Number _ -> None)
;;

let rate_limits payload =
  (* Prefer an explicit rate_limits child, else search the whole payload. *)
  match J.member "rate_limits" payload with
  | Some child when is_rate_limit_map child -> Some child
  | Some _ | None -> find_rate_limits payload
;;

module Counters = struct
  type t =
    { input : int
    ; output : int
    ; total : int
    ; input_watermark : int
    ; output_watermark : int
    ; total_watermark : int
    }
  [@@deriving sexp_of]

  let empty =
    { input = 0
    ; output = 0
    ; total = 0
    ; input_watermark = 0
    ; output_watermark = 0
    ; total_watermark = 0
    }
  ;;

  let input t = t.input
  let output t = t.output
  let total t = t.total

  let apply t (usage : Usage.t) =
    let step counter watermark next =
      let delta = Int.max 0 (next - watermark) in
      counter + delta, Int.max watermark next, delta
    in
    let input, input_watermark, input_delta =
      step t.input t.input_watermark usage.input
    in
    let output, output_watermark, output_delta =
      step t.output t.output_watermark usage.output
    in
    let total, total_watermark, total_delta =
      step t.total t.total_watermark usage.total
    in
    ( { input; output; total; input_watermark; output_watermark; total_watermark }
    , { Usage.input = input_delta; output = output_delta; total = total_delta } )
  ;;
end
