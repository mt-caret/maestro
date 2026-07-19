open! Core

module Path = struct
  type t =
    { root : string
    ; rest : string list
    }
  [@@deriving sexp_of]

  let to_string { root; rest } = String.concat ~sep:"." (root :: rest)

  let segment_ok segment =
    (not (String.is_empty segment))
    && String.for_all segment ~f:(fun c -> Char.is_alphanum c || Char.equal c '_')
    && not (Char.is_digit (String.get segment 0))
  ;;

  let of_expression expression =
    match String.substr_index expression ~pattern:"|" with
    | Some _ ->
      Or_error.error_s
        [%message
          "filters are not supported by this template engine (strict mode)" expression]
    | None ->
      (match String.strip expression |> String.split ~on:'.' with
       | root :: rest when List.for_all (root :: rest) ~f:segment_ok -> Ok { root; rest }
       | _ ->
         Or_error.error_s
           [%message
             "expected a dotted identifier path, e.g. issue.title"
               ~expression:(String.strip expression : string)])
  ;;
end

module Node = struct
  type t =
    | Text of string
    | Output of Path.t
    | If of
        { condition : Path.t
        ; then_ : t list
        ; else_ : t list
        }
    | For of
        { binding : string
        ; over : Path.t
        ; body : t list
        }
  [@@deriving sexp_of]
end

type t = Node.t list [@@deriving sexp_of]

module Token = struct
  type t =
    | Text of string
    | Output of string
    | Tag of string
  [@@deriving sexp_of]
end

let tokenize template : Token.t list Or_error.t =
  let rec loop pos acc =
    if pos >= String.length template
    then Ok (List.rev acc)
    else (
      let next_output = String.substr_index template ~pos ~pattern:"{{" in
      let next_tag = String.substr_index template ~pos ~pattern:"{%" in
      let next_marker =
        match next_output, next_tag with
        | None, None -> None
        | Some i, None -> Some (i, `Output)
        | None, Some i -> Some (i, `Tag)
        | Some i, Some j -> if i < j then Some (i, `Output) else Some (j, `Tag)
      in
      match next_marker with
      | None -> Ok (List.rev (Token.Text (String.subo template ~pos) :: acc))
      | Some (start, kind) ->
        let acc =
          match start > pos with
          | true -> Token.Text (String.sub template ~pos ~len:(start - pos)) :: acc
          | false -> acc
        in
        let closer, construct =
          match kind with
          | `Output -> "}}", fun s -> Token.Output s
          | `Tag -> "%}", fun s -> Token.Tag s
        in
        (match String.substr_index template ~pos:(start + 2) ~pattern:closer with
         | None ->
           Or_error.error_s
             [%message
               "unclosed template marker"
                 ~marker:(String.sub template ~pos:start ~len:2 : string)
                 ~at_offset:(start : int)]
         | Some close ->
           let inner = String.sub template ~pos:(start + 2) ~len:(close - start - 2) in
           loop (close + 2) (construct (String.strip inner) :: acc)))
  in
  loop 0 []
;;

module Tag = struct
  type t =
    | If of Path.t
    | Else
    | Endif
    | For of
        { binding : string
        ; over : Path.t
        }
    | Endfor

  let parse content =
    match String.split content ~on:' ' |> List.filter ~f:(Fn.non String.is_empty) with
    | [ "if"; expression ] ->
      let%map.Or_error condition = Path.of_expression expression in
      If condition
    | [ "else" ] -> Ok Else
    | [ "endif" ] -> Ok Endif
    | [ "for"; binding; "in"; expression ] when Path.segment_ok binding ->
      let%map.Or_error over = Path.of_expression expression in
      For { binding; over }
    | [ "endfor" ] -> Ok Endfor
    | _ -> Or_error.error_s [%message "unknown or malformed template tag" content]
  ;;
end

(* Recursive-descent parse of the token stream. [parse_nodes] accumulates nodes until it
   hits a terminator tag belonging to the enclosing construct (else/endif/endfor), which
   it returns to the caller along with the remaining tokens. *)
let rec parse_nodes tokens ~context
  : (Node.t list * [ `Else | `Endif | `Endfor | `Eof ] * Token.t list) Or_error.t
  =
  match (tokens : Token.t list) with
  | [] ->
    (match context with
     | `Top -> Ok ([], `Eof, [])
     | `If ->
       Or_error.error_s [%message "unclosed template block" ~expected:"{% endif %}"]
     | `For ->
       Or_error.error_s [%message "unclosed template block" ~expected:"{% endfor %}"])
  | Text text :: rest ->
    let%map.Or_error nodes, terminator, remaining = parse_nodes rest ~context in
    Node.Text text :: nodes, terminator, remaining
  | Output expression :: rest ->
    let%bind.Or_error path = Path.of_expression expression in
    let%map.Or_error nodes, terminator, remaining = parse_nodes rest ~context in
    Node.Output path :: nodes, terminator, remaining
  | Tag content :: rest ->
    (match%bind.Or_error Tag.parse content with
     | If condition ->
       let%bind.Or_error then_, terminator, rest = parse_nodes rest ~context:`If in
       let%bind.Or_error else_, rest =
         match terminator with
         | `Else ->
           let%bind.Or_error else_, terminator, rest = parse_nodes rest ~context:`If in
           (match terminator with
            | `Endif -> Ok (else_, rest)
            | `Else -> Or_error.error_s [%message "duplicate {% else %} in one {% if %}"]
            | `Endfor | `Eof -> assert false)
         | `Endif -> Ok ([], rest)
         | `Endfor | `Eof -> assert false
       in
       let%map.Or_error nodes, terminator, remaining = parse_nodes rest ~context in
       Node.If { condition; then_; else_ } :: nodes, terminator, remaining
     | For { binding; over } ->
       let%bind.Or_error body, terminator, rest = parse_nodes rest ~context:`For in
       (match terminator with
        | `Endfor ->
          let%map.Or_error nodes, terminator, remaining = parse_nodes rest ~context in
          Node.For { binding; over; body } :: nodes, terminator, remaining
        | `Else -> Or_error.error_s [%message "{% else %} is not valid inside {% for %}"]
        | `Endif | `Eof -> assert false)
     | Else ->
       (match context with
        | `If -> Ok ([], `Else, rest)
        | `Top | `For ->
          Or_error.error_s [%message "{% else %} outside of an {% if %} block"])
     | Endif ->
       (match context with
        | `If -> Ok ([], `Endif, rest)
        | `Top | `For ->
          Or_error.error_s [%message "{% endif %} without a matching {% if %}"])
     | Endfor ->
       (match context with
        | `For -> Ok ([], `Endfor, rest)
        | `Top | `If ->
          Or_error.error_s [%message "{% endfor %} without a matching {% for %}"]))
;;

let parse template =
  (let%bind.Or_error tokens = tokenize template in
   let%map.Or_error nodes, (_ : [ `Else | `Endif | `Endfor | `Eof ]), (_ : Token.t list) =
     (* [parse_nodes ~context:`Top] only returns [`Eof] with an empty remainder; stray
        terminator tags error inside it. *)
     parse_nodes tokens ~context:`Top
   in
   nodes)
  |> Or_error.tag ~tag:"template_parse_error"
;;

let find_field fields ~segment ~path =
  match List.Assoc.find fields segment ~equal:String.equal with
  | Some value -> Ok value
  | None ->
    Or_error.error_s [%message "unknown variable" ~path:(Path.to_string path : string)]
;;

let lookup ~bindings ~vars ({ Path.root; rest } as path) =
  let root_value =
    match List.Assoc.find bindings root ~equal:String.equal with
    | Some value -> Ok value
    | None ->
      (match (vars : Jsonaf.t) with
       | `Object fields -> find_field fields ~segment:root ~path
       | (`Null | `True | `False | `String _ | `Number _ | `Array _) as vars ->
         Or_error.error_s
           [%message "template variables must be an object" (vars : Jsonaf.t)])
  in
  List.fold rest ~init:root_value ~f:(fun value segment ->
    match%bind.Or_error value with
    | `Object fields -> find_field fields ~segment ~path
    | (`Null | `True | `False | `String _ | `Number _ | `Array _) as value ->
      Or_error.error_s
        [%message
          "cannot look up a field inside a non-object value"
            ~path:(Path.to_string path : string)
            ~field:(segment : string)
            (value : Jsonaf.t)])
;;

let rec value_to_string (value : Jsonaf.t) =
  match value with
  | `Null -> Ok ""
  | `True -> Ok "true"
  | `False -> Ok "false"
  | `String s -> Ok s
  | `Number literal -> Ok literal
  | `Array values ->
    let%map.Or_error rendered = List.map values ~f:value_to_string |> Or_error.all in
    String.concat rendered
  | `Object _ as value ->
    Or_error.error_s [%message "cannot render an object value" (value : Jsonaf.t)]
;;

let rec render_nodes nodes ~bindings ~vars =
  let%map.Or_error rendered =
    List.map nodes ~f:(fun (node : Node.t) ->
      match node with
      | Text text -> Ok text
      | Output path ->
        let%bind.Or_error value = lookup ~bindings ~vars path in
        value_to_string value
      | If { condition; then_; else_ } ->
        let%bind.Or_error condition = lookup ~bindings ~vars condition in
        let branch =
          match condition with
          | `Null | `False -> else_
          | `True | `String _ | `Number _ | `Array _ | `Object _ -> then_
        in
        render_nodes branch ~bindings ~vars
      | For { binding; over; body } ->
        (match%bind.Or_error lookup ~bindings ~vars over with
         | `Array values ->
           let%map.Or_error iterations =
             List.map values ~f:(fun value ->
               render_nodes body ~bindings:((binding, value) :: bindings) ~vars)
             |> Or_error.all
           in
           String.concat iterations
         | (`Null | `True | `False | `String _ | `Number _ | `Object _) as value ->
           Or_error.error_s
             [%message
               "cannot iterate over a non-array value"
                 ~path:(Path.to_string over : string)
                 (value : Jsonaf.t)]))
    |> Or_error.all
  in
  String.concat rendered
;;

let render t ~vars =
  render_nodes t ~bindings:[] ~vars |> Or_error.tag ~tag:"template_render_error"
;;
