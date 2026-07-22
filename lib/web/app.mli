(** Browser entry component that polls the authoritative JSON API. *)

open! Core
open Bonsai_web

val component : local_ Bonsai.graph -> Vdom.Node.t Bonsai.t
