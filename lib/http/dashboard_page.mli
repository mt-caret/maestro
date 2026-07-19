(** The self-contained HTML dashboard served at [/] — inline CSS and JS that poll
    [/api/v1/state], with no external asset dependencies (SPEC §13.7.1). *)

open! Core

val html : string
