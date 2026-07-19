(** Token and rate-limit extraction from Codex update payloads (SPEC §13.5;
    docs/token_accounting.md).

    Only absolute cumulative totals are counted, never delta-style payloads. Totals
    accumulate as high-water-marked deltas so re-reported cumulative snapshots are not
    double-counted. Classification is by event type and payload path — never by field name
    alone. *)

open! Core

module Usage : sig
  type t =
    { input : int
    ; output : int
    ; total : int
    }
  [@@deriving sexp_of]
end

(** The absolute-total usage carried by a payload, if any, tried in this precedence:
    [params.msg.payload.info.total_token_usage], [params.msg.info.total_token_usage],
    [params.tokenUsage.total], [tokenUsage.total], then — only when the payload's method
    is [turn/completed] — its [usage]. Delta-style fields ([last_token_usage],
    [tokenUsage.last]) are ignored. Component values are read leniently across snake- and
    camel-case names. *)
val absolute_usage : Jsonaf.t -> Usage.t option

(** The latest rate-limit payload: the first map (depth-first) carrying a
    [limit_id]/[limit_name] plus any of [primary]/[secondary]/[credits], returned
    verbatim. *)
val rate_limits : Jsonaf.t -> Jsonaf.t option

module Counters : sig
  (** Per-session token counters with per-component high-water marks. *)
  type t [@@deriving sexp_of]

  val empty : t
  val input : t -> int
  val output : t -> int
  val total : t -> int

  (** [apply t usage] accumulates [usage] as the positive delta above each component's
      watermark, returning the updated counters and the [(input, output, total)] deltas to
      add to global aggregates. *)
  val apply : t -> Usage.t -> t * Usage.t
end
