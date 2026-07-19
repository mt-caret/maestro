(** Typed runtime settings parsed from WORKFLOW.md front matter (SPEC §5.3, §6).

    Defaults, [$VAR] environment indirection, and normalization mirror the reference
    implementation except where PLAN.md §7 records a divergence. Unknown top-level keys
    and unknown section fields are ignored for forward compatibility. *)

open! Core

(** Compare provider-native state names after trimming and lowercasing (SPEC §4.2). *)
val normalize_state_name : string -> string

module Tracker : sig
  type t =
    { kind : string option
    (** [None] fails dispatch preflight with [missing_tracker_kind]. *)
    ; provider : (string * Jsonaf.t) list
    (** Adapter-owned config with unknown keys preserved verbatim and [$VAR] references
        kept literal (safe to print). For [kind = linear], the legacy top-level
        [endpoint]/[api_key]/[project_slug]/[assignee] aliases are merged in with existing
        provider keys winning, and a default endpoint is injected. *)
    ; resolved_provider : (string * Jsonaf.t) list
    (** [provider] with documented secret keys resolved through [$VAR]/env fallbacks —
        what adapters consume. Deliberately opaque in sexps so secrets never reach logs. *)
    ; required_labels : string list (** Trimmed, lowercased, deduplicated. *)
    ; active_states : string list option
    ; terminal_states : string list option
    (** State lists default for kinds [linear] and [memory] only; other kinds must
        configure them (or their adapter profile must document a default). *)
    ; secret_environment_names : string list
    (** Environment variable names scrubbed from the coding-agent child process. *)
    }
  [@@deriving sexp_of]
end

module Polling : sig
  type t = { interval : Time_ns.Span.t (** Default 30s; must be positive. *) }
  [@@deriving sexp_of]
end

module Workspace : sig
  type t =
    { root : string
    (** Absolute. [$VAR]/[~] expanded; a relative configured value resolves against the
        directory containing WORKFLOW.md (SPEC §5.3.3; diverges from the reference's
        cwd-relative resolution). Default: [$TMPDIR/symphony_workspaces], falling back to
        [/tmp/symphony_workspaces]. *)
    }
  [@@deriving sexp_of]
end

module Hooks : sig
  type t =
    { after_create : string option
    ; before_run : string option
    ; after_run : string option
    ; before_remove : string option
    ; timeout : Time_ns.Span.t (** Default 60s; must be positive. *)
    }
  [@@deriving sexp_of]
end

module Agent : sig
  type t =
    { max_concurrent_agents : int (** Default 10; positive. *)
    ; max_turns : int (** Default 20; positive. *)
    ; max_retry_backoff : Time_ns.Span.t (** Default 5m; positive. *)
    ; max_concurrent_agents_by_state : int String.Map.t
    (** Keys normalized via [normalize_state_name]. Invalid entries (blank key,
        non-positive or non-integer limit) are ignored per SPEC §5.3.5 and reported in
        [warnings] (diverges from the reference, which rejects them). *)
    }
  [@@deriving sexp_of]
end

module Codex : sig
  type t =
    { command : string (** Default ["codex app-server"]; must be non-blank. *)
    ; approval_policy : Jsonaf.t
    (** String or object, passed through verbatim. Default:
        [{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}].
        Client-side auto-approval keys on the literal string ["never"]. *)
    ; thread_sandbox : string (** Default ["workspace-write"]; any string accepted. *)
    ; turn_sandbox_policy : Jsonaf.t option
    (** Passed through verbatim when configured; [None] synthesizes the default
        workspace-rooted policy at launch time. *)
    ; turn_timeout : Time_ns.Span.t (** Default 1h; positive. *)
    ; read_timeout : Time_ns.Span.t (** Default 5s; positive. *)
    ; stall_timeout : Time_ns.Span.t option
    (** [None] disables stall detection. Configured values [<= 0] parse to [None] (SPEC
        §5.3.6). Default 5m. *)
    }
  [@@deriving sexp_of]
end

module Observability : sig
  type t =
    { dashboard_enabled : bool (** Default true. *)
    ; refresh : Time_ns.Span.t
    (** Snapshot poll cadence for status surfaces; default 1s. *)
    }
  [@@deriving sexp_of]
end

module Server : sig
  type t =
    { port : int option (** [None] disables the HTTP extension. [0] = ephemeral port. *)
    ; host : string (** Default loopback ["127.0.0.1"]. *)
    }
  [@@deriving sexp_of]
end

type t =
  { tracker : Tracker.t
  ; polling : Polling.t
  ; workspace : Workspace.t
  ; hooks : Hooks.t
  ; agent : Agent.t
  ; codex : Codex.t
  ; observability : Observability.t
  ; server : Server.t
  ; warnings : Error.t list
  (** Non-fatal parse findings (e.g. ignored per-state limit entries), for the caller to
      log once. *)
  }
[@@deriving sexp_of]

(** [of_front_matter front_matter ~workflow_dir ~getenv] parses and validates the YAML
    front matter root object. [workflow_dir] anchors relative [workspace.root] values;
    [getenv] backs [$VAR] resolution and [~] expansion (pass [Sys.getenv] in production).
    Validation failures return errors whose sexp starts with [invalid_workflow_config],
    listing every offending dotted path. *)
val of_front_matter
  :  Jsonaf.t
  -> workflow_dir:string
  -> getenv:(string -> string option)
  -> t Or_error.t

(** Per-state limit lookup: normalized-key map hit, else the global limit (SPEC §8.3). *)
val max_concurrent_agents_for_state : t -> state:string -> int
