(** WORKFLOW.md loader: front-matter split, YAML decode, typed config (SPEC §5.1, §5.2).

    A file starting with a line that is exactly [---] carries YAML front matter up to the
    next such line (an unterminated block is accepted: everything is front matter and the
    prompt is empty). Otherwise the whole file is the prompt template and the config is
    empty. Whitespace-only front matter parses as an empty map; non-map YAML is the
    [workflow_front_matter_not_a_map] error; YAML errors are [workflow_parse_error]; an
    unreadable file is [missing_workflow_file]. *)

open! Core
open! Async

module Loaded : sig
  type t =
    { config : Config.t
    ; prompt_template : string (** Markdown body, trimmed. *)
    ; front_matter : Jsonaf.t (** Raw front-matter root object. *)
    }
  [@@deriving sexp_of]
end

val load : path:string -> getenv:(string -> string option) -> Loaded.t Deferred.Or_error.t

(** Pure split/parse of file contents; [workflow_dir] anchors relative workspace roots.
    [load] is this plus the file read. *)
val parse_contents
  :  string
  -> workflow_dir:string
  -> getenv:(string -> string option)
  -> Loaded.t Or_error.t

(** Compact, backtrace-free description of a file-read exception, for
    [missing_workflow_file] errors. *)
val read_failure_reason : exn -> string
