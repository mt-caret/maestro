(** The normalized, schedulable work item every adapter produces (SPEC §4.1.1, §11.3).

    [id] is an opaque dispatch identity within the configured tracker scope — never assume
    it is the provider's underlying ticket id (that may live in [native_ref]).
    [identifier] is the human-readable key ([MT-101]) that names workspaces and
    operator-facing routes, unique within scope. [state] keeps the provider's spelling;
    scheduler comparisons normalize both sides. [dispatchable] is adapter-derived
    provider-specific eligibility; the scheduler applies states, labels, claims, and
    concurrency on top. *)

open! Core

module Blocker : sig
  (** Best-effort provider metadata; adapters must not invent blocker semantics. *)
  type t =
    { id : string option
    ; identifier : string option
    ; state : string option
    }
  [@@deriving sexp_of]

  module Stable : sig
    module V1 : sig
      type t =
        { id : string option
        ; identifier : string option
        ; state : string option
        }
      [@@deriving bin_io, sexp, stable_witness]
    end
  end
end

type t =
  { id : string
  ; native_ref : Jsonaf.t option
  ; identifier : string
  ; title : string
  ; description : string option
  ; priority : int option (** Lower is more urgent; the scheduler ranks 1..4 first. *)
  ; state : string
  ; branch_name : string option
  ; url : string option
  ; assignee_id : string option
  ; labels : string list (** Trimmed, lowercased, deduplicated, blanks dropped. *)
  ; blocked_by : Blocker.t list
  ; dispatchable : bool
  ; created_at : Time_ns.t option
  ; updated_at : Time_ns.t option
  }
[@@deriving sexp_of]

module Stable : sig
  module V1 : sig
    type t =
      { id : string
      ; native_ref : string option
      ; identifier : string
      ; title : string
      ; description : string option
      ; priority : int option
      ; state : string
      ; branch_name : string option
      ; url : string option
      ; assignee_id : string option
      ; labels : string list
      ; blocked_by : Blocker.Stable.V1.t list
      ; dispatchable : bool
      ; created_at : Time_ns.Stable.V1.t option
      ; updated_at : Time_ns.Stable.V1.t option
      }
    [@@deriving bin_io, sexp, stable_witness]
  end
end

val to_stable_v1 : t -> Stable.V1.t
val of_stable_v1 : Stable.V1.t -> t Or_error.t

(** [routable t ~required_labels] — adapter-level eligibility for refresh/continuation
    checks (SPEC §8.2): [dispatchable] and every required label present
    (case/whitespace-insensitively). States, claims, and concurrency are checked
    separately by the scheduler. *)
val routable : t -> required_labels:string list -> bool
