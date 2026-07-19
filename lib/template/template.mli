(** Strict Liquid-subset template engine for WORKFLOW.md prompt bodies (SPEC §5.4, §12.2).

    Supported syntax:
    - [{{ path.to.value }}] interpolation
    - [{% if path %}] … [{% else %}] … [{% endif %}]
    - [{% for name in path %}] … [{% endfor %}]

    Strictness (SPEC MUSTs): a path that does not resolve in the variable tree fails
    rendering, and any [|] filter fails parsing — this engine implements no filters, so
    every filter is unknown. A path bound to [`Null] resolves (it renders as the empty
    string and is falsy), which is how [attempt] stays strict-safe on first runs.

    Value semantics mirror Liquid as the reference implementation exercises it: strings
    render verbatim, numbers as their literal text, booleans as [true]/[false], arrays as
    the concatenation of their rendered elements, and objects are a render error. [if] is
    falsy exactly on [`Null] and [`False]. *)

open! Core

type t

(** [parse template] compiles the template, rejecting malformed or unbalanced syntax and
    any use of filters. Errors are tagged [template_parse_error]. *)
val parse : string -> t Or_error.t

(** [render t ~vars] renders against [vars], which must be an [`Object]. Unresolvable
    paths and unrenderable values fail with errors tagged [template_render_error]. *)
val render : t -> vars:Jsonaf.t -> string Or_error.t
