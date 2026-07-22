(** A synchronous, read-only projection of orchestrator state for status surfaces (SPEC
    §13.3). Derived from state only; never required for correctness. *)

include module type of Maestro_snapshot.Snapshot
