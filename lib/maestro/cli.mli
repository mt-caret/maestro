(** The [maestro] command-line entry point (SPEC §17.7). *)

open! Core
open! Async

val command : Command.t
