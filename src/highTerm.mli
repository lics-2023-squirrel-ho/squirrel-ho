(** Module build on top of [Term] and [Env] *)

module SE = SystemExpr

(*------------------------------------------------------------------*)
include module type of Term

module Smart : SmartFO.S with type form = Term.term

(*------------------------------------------------------------------*)
(** Check if a term semantics is independent of the system (among all 
    compatible systems, hence actions are allowed). *)
val is_system_indep : Env.t -> Term.term -> bool 

(** Check if a term represents a deterministic (i.e. 
    non-probabilistic) computation:
    - [`Exact] always
    - [`Approx] overwhelmingly  *)
val is_deterministic : Env.t -> Term.term -> bool

(** Check if a term represents a constant (i.e. 
    non-probabilistic and η-independent) computation:
    - [`Exact] always
    - [`Approx] overwhelmingly *)
val is_constant : [`Exact | `Approx] -> Env.t -> Term.term -> bool

(** Check if a term is deducible in ptime by an adversary with no direct 
    access to the protocol randomness.
    This requires that the term is:
    - deterministic
    - uses only ptime computable functions *)
val is_ptime_deducible : 
  const:[`Exact | `Approx] -> 
  si:bool ->
  Env.t -> Term.term -> bool

