(*
Copyright (c) 2013, Simon Cruanes
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.  Redistributions in binary
form must reproduce the above copyright notice, this list of conditions and the
following disclaimer in the documentation and/or other materials provided with
the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*)

(** {6 Top-Down Computation} *)

(** This module implements top-down computation of Datalog queries
    with non-stratified negation.

    See "efficient top-down computation of queries under the well-founded
    semantics"
*)

module type S = sig
  type const
  
  val set_debug : bool -> unit

  (** {2 Terms} *)

  module T : sig
    type t = private
    | Var of int
    | Apply of const * t array

    val mk_var : int -> t
    val mk_const : const -> t
    val mk_apply : const -> t array -> t
    val mk_apply_l : const -> t list -> t

    val is_var : t -> bool
    val is_apply : t -> bool
    val is_const : t -> bool

    val eq : t -> t -> bool
    val hash : t -> int

    val ground : t -> bool
    val vars : t -> int list
    val max_var : t -> int    (** max var, or 0 if ground *)
    val head_symbol : t -> const

    val to_string : t -> string
    val pp : out_channel -> t -> unit
    val fmt : Format.formatter -> t -> unit

    module Tbl : Hashtbl.S with type key = t
  end

  (** {2 Literals} *)

  module Lit : sig
    type t =
    | LitPos of T.t
    | LitNeg of T.t

    val mk_pos : T.t -> t
    val mk_neg : T.t -> t
    val mk : bool -> T.t -> t

    val eq : t -> t -> bool
    val hash : t -> int

    val to_term : t -> T.t
    val fmap : (T.t -> T.t) -> t -> t

    val to_string : t -> string
    val pp : out_channel -> t -> unit
    val fmt : Format.formatter -> t -> unit
  end

  (** {2 Clauses} *)

  module C : sig
    type t = private {
      head : T.t;
      body : Lit.t list;
    }

    exception Unsafe

    val mk_clause : T.t -> Lit.t list -> t
    val mk_fact : T.t -> t

    val eq : t -> t -> bool
    val hash : t -> int

    val head_symbol : t -> const
    val max_var : t -> int
    val fmap : (T.t -> T.t) -> t -> t

    val to_string : t -> string
    val pp : out_channel -> t -> unit
    val fmt : Format.formatter -> t -> unit

    module Tbl : Hashtbl.S with type key = t
  end

  (** {2 Substs} *)

  (** This module is used for variable bindings. *)

  module Subst : sig
    type t
    type scope = int
    type renaming

    val empty : t
      (** Empty subst *)
    
    val bind : t -> T.t -> scope -> T.t -> scope -> t
      (** Bind a variable,scope to a term,scope *)

    val deref : t -> T.t -> scope -> T.t * scope
      (** While the term is a variable bound in subst, follow its binding.
          Returns the final term and scope *)

    val create_renaming : unit -> renaming

    val reset_renaming : renaming -> unit

    val rename : renaming:renaming -> T.t -> scope -> T.t
      (** Rename the given variable into a variable that is unique
          within variables known to the given [renaming] *)

    val eval : t -> renaming:renaming -> T.t -> scope -> T.t
      (** Apply the substitution to the term. Free variables are renamed
          using [renaming] *)

    val eval_lit : t -> renaming:renaming -> Lit.t -> scope -> Lit.t

    val eval_lits : t -> renaming:renaming -> Lit.t list -> scope -> Lit.t list

    val eval_clause : t -> renaming:renaming -> C.t -> scope -> C.t
  end

  (** {2 Unification, matching...} *)

  type scope = Subst.scope

  exception UnifFail

  (** For {!unify} and {!match_}, the optional parameter [oc] is used to
      enable or disable occur-check. It is disabled by default. *)

  val unify : ?oc:bool -> ?subst:Subst.t -> T.t -> scope -> T.t -> scope -> Subst.t
    (** Unify the two terms.
        @raise UnifFail if it fails *)

  val match_ : ?oc:bool -> ?subst:Subst.t -> T.t -> scope -> T.t -> scope -> Subst.t
    (** [match_ a sa b sb] matches the pattern [a] in scope [sa] with term
        [b] in scope [sb].
        @raise UnifFail if it fails *)

  val alpha_equiv : ?subst:Subst.t -> T.t -> scope -> T.t -> scope -> Subst.t
    (** Test for alpha equivalence.
        @raise UnifFail if it fails *)

  val are_alpha_equiv : T.t -> T.t -> bool
    (** Special version of [alpha_equiv], using distinct scopes for the two
        terms to test, and discarding the result *)

  val clause_are_alpha_equiv : C.t -> C.t -> bool
    (** Alpha equivalence of clauses. *)

  (** The following hashtables use alpha-equivalence checking instead of
      regular, syntactic equality *)

  module TVariantTbl : Hashtbl.S with type key = T.t
  module CVariantTbl : Hashtbl.S with type key = C.t

  (** {2 DB} *)

  (** A DB stores facts and clauses, that constitute a logic program.
      Facts and clauses can only be added.

      Non-stratified programs will be rejected with NonStratifiedProgram.
  *)

  exception NonStratifiedProgram

  module DB : sig
    type t
      (** A database is a repository for Datalog clauses. *)

    type interpreter = T.t -> C.t list
      (** Interpreted predicate. It takes terms which have a given
          symbol as head, and return a list of (safe) clauses that
          have the same symbol as head, and should unify with the
          query term. *)

    val create : ?parent:t -> unit -> t

    val copy : t -> t

    val add_fact : t -> T.t -> unit
    val add_facts : t -> T.t list -> unit

    val add_clause : t -> C.t -> unit
    val add_clauses : t -> C.t list -> unit

    val interpret : t -> const -> interpreter -> unit
      (** Add an interpreter for the given constant. Goals that start with
          this constant will be given to all registered interpreters, all
          of which can add new clauses. The returned clauses must
          have the constant as head symbol. *)

    val interpret_list : t -> (const * interpreter) list -> unit
      (** Add several interpreters *)

    val is_interpreted : t -> const -> bool
      (** Is the constant interpreted by some OCaml code? *)

    val num_facts : t -> int
    val num_clauses : t -> int
    val size : t -> int

    val find_facts : ?oc:bool -> t -> scope -> T.t -> scope ->
                     (T.t -> Subst.t -> unit) -> unit
      (** find facts unifying with the given term, and give them
          along with the unifier, to the callback *)

    val find_clauses_head : ?oc:bool -> t -> scope -> T.t -> scope ->
                            (C.t -> Subst.t -> unit) -> unit
      (** find clauses whose head unifies with the given term,
          and give them along with the unifier, to the callback *)

    val find_interpretation : ?oc:bool -> t -> scope -> T.t -> scope ->
                              (C.t -> Subst.t -> unit) -> unit
      (** Given an interpreted goal, try all interpreters on it,
          and match the query against their heads. Returns clauses
          whose head unifies with the goal, along with the substitution. *)
  end

  (** {2 Query} *)

  val ask : ?oc:bool -> ?with_rules:C.t list -> ?with_facts:T.t list ->
            DB.t -> T.t -> T.t list
    (** Returns the answers to a query in a given DB. Additional facts and rules can be
        added in a local scope.
        @param oc enable occur-check in unification (default [false]) *)

  val ask_lits : ?oc:bool -> ?with_rules:C.t list -> ?with_facts:T.t list ->
                 DB.t -> T.t list -> Lit.t list -> T.t list list
    (** Extension of {! ask}, where the query ranges over the list of
        variables (the term list), all of which must be bound in
        the list of literals that form a constraint.

        [ask_lits db vars lits] queries over variables [vars] with
        the constraints given by [lits]. 

        Conceptually, the query adds a clause (v1, ..., vn) :- lits, which
        should respect the same safety constraint as other clauses.

        @return a list of answers, each of which is a list of terms that
          map to the given list of variables.
        *)
end

module type CONST = sig
  type t

  val equal : t -> t -> bool
  val hash : t -> int
  val to_string : t -> string

  val query : t
    (** Special symbol, that will never occur in any user-defined
        clause or term. For strings, this may be the empty string "". *)
end

(** {2 Generic implementation} *)

module Make(Const : CONST) : S with type const = Const.t

(** {2 Default Implementation with Strings} *)

module Default : sig
  include S with type const = string

  type name_ctx = (string, T.t) Hashtbl.t

  val create_ctx : unit -> name_ctx

  val term_of_ast : ctx:name_ctx -> TopDownAst.term -> T.t
  val lit_of_ast : ctx:name_ctx -> TopDownAst.literal -> Lit.t 
  val clause_of_ast : ?ctx:name_ctx -> TopDownAst.clause -> C.t
  val clauses_of_ast : ?ctx:name_ctx -> TopDownAst.clause list -> C.t list

  val default_interpreters : (const * DB.interpreter) list
    (** List of default interpreters for some symbols, mostly
        infix predicates *)
end
