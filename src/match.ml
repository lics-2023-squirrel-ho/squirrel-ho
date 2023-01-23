open Utils
open Term

module Sv = Vars.Sv
module Mv = Vars.Mv

module TraceHyps = Hyps.TraceHyps
                     
module SE = SystemExpr

let dbg ?(force=false) s =
  if force then Printer.prt `Dbg s
  else Printer.prt `Ignore s

(*------------------------------------------------------------------*)
(** {2 Positions} *)

module Pos = struct
  (** A position, represented by a list of integer.
      The position [pos @ [i]] of [f(t0,...,tn)] is the position 
      [pos] of [ti]. 
      If [i < 0] or [t > n], the position is invalid. 

      Note that the list is in reversed order compared to the intuitive 
      representation. Since we build an use positions in that order, this
      is more efficient. *)
  type pos = int list

  let root = []

  let pp (fmt : Format.formatter) (pos : pos) : unit =
    if pos = [] then Fmt.pf fmt "ε"
    else Fmt.list ~sep:(Fmt.any ".") Fmt.int fmt pos

  (*------------------------------------------------------------------*)
  let rec lt (p1 : pos) (p2 : pos) : bool =
    match p1, p2 with
    | x1 :: p1, x2 :: p2 -> x1 = x2 && lt p1 p2
    | [], _ -> true
    | _, [] -> false

  (*------------------------------------------------------------------*)
  module Sp = Set.Make (struct
      type t = pos
      let compare = Stdlib.compare
    end)

  (*------------------------------------------------------------------*)
  type f_sel =
    Term.term -> Term.projs option -> Vars.vars -> Term.term list ->
    [`Select | `Continue]

  (*------------------------------------------------------------------*)
  (* [p] is the current position *)
  let rec sel
      (fsel : f_sel) (sp : Sp.t)
      ~projs ~vars ~conds ~(p : pos)
      (t : Term.term)
    = 
    match fsel t projs vars conds with
    | `Select -> Sp.add p sp
    | `Continue -> 
      match t with
      | Term.Fun (fs, _, [c;t;e]) when fs = Term.f_ite ->
        let conds_t =             c :: conds in
        let conds_e = Term.mk_not c :: conds in

        let sp = sel fsel sp ~projs ~vars ~conds         ~p:(0 :: p) c in
        let sp = sel fsel sp ~projs ~vars ~conds:conds_t ~p:(1 :: p) t in
        (*    *) sel fsel sp ~projs ~vars ~conds:conds_e ~p:(2 :: p) e 

      | Term.Fun (_, _, l) ->
        sel_l fsel sp ~projs ~vars ~conds ~p l

      | Term.App (t1, l) ->
        sel_l fsel sp ~projs ~vars ~conds ~p (t1 :: l)

      | Term.Name (_ns,l) ->
        sel_l fsel sp ~projs ~vars ~conds ~p l

      | Term.Macro (_ms, terms, ts) ->
        let l = terms @ [ts] in
        sel_l fsel sp ~projs ~vars ~conds ~p l

      | Term.Action (_, l) ->
        sel_l fsel sp ~projs ~vars ~conds ~p l

      | Term.Var _ -> sp

      | Term.Tuple ts ->
        sel_l fsel sp ~projs ~vars ~conds ~p ts

      | Term.Proj (_, t) ->
        sel fsel sp ~projs ~vars ~conds ~p:(0 :: p) t

      | Term.Diff (Explicit l) ->
        List.foldi (fun i sp (label,t) ->
            sel fsel sp ~projs:(Some [label]) ~vars ~conds ~p:(i :: p) t
          ) sp l

      | Term.Quant (_, is, t) -> 
        let is, subst = Term.refresh_vars is in
        let t = Term.subst subst t in
        let vars = List.rev_append is vars in
        sel fsel sp ~projs ~vars ~conds ~p:(0 :: p) t

      | Term.Find (is, c, t, e) ->
        let is, subst = Term.refresh_vars is in
        let c = Term.subst subst c in
        let t = Term.subst subst t in

        let vars1 = List.rev_append is vars in

        let conds_t = c :: conds in
        let conds_e = Term.mk_forall is (Term.mk_not c) :: conds in

        let sp = sel fsel sp ~projs ~vars:vars1 ~conds         ~p:(0 :: p) c in
        let sp = sel fsel sp ~projs ~vars:vars1 ~conds:conds_t ~p:(1 :: p) t in
        (*    *) sel fsel sp ~projs ~vars       ~conds:conds_e ~p:(2 :: p) e 

  and sel_l fsel (sp : Sp.t) ~projs ~vars ~conds ~(p : pos) (l : Term.term list) = 
    List.foldi (fun i sp t -> sel fsel sp ~projs ~vars ~conds ~p:(i :: p) t) sp l 


  (** Exported *)
  let select (fsel : f_sel) (t : Term.term) : Sp.t =
    sel fsel Sp.empty ~projs:None ~vars:[] ~conds:[] ~p:[] t

  (*------------------------------------------------------------------*)
  (** Exported *)
  let select_e (fsel : f_sel) (t : Equiv.form) : Sp.t =

    (* [p] is the current position *)
    let rec sel_e (sp : Sp.t) ~projs ~vars ~conds ~(p : pos) (t : Equiv.form) =  
      match t with
      | Equiv.Quant (_q, is, t0) ->
        let is, subst = Term.refresh_vars_w_info is in
        let t0 = Equiv.subst subst t0 in
        let vars = List.rev_append (List.map fst is) vars in
        (* FEATURE: add tags in Fold.map *)
        sel_e sp ~projs ~vars ~conds ~p:(0 :: p) t0

      | Equiv.Atom (Reach t) ->
        let projs = Some [Term.left_proj; Term.right_proj] in
        sel fsel sp ~projs ~vars ~conds ~p:(0 :: 0 :: p) t

      | Equiv.Atom (Equiv e) -> 
        sel_l fsel sp ~projs ~vars ~conds ~p:(0 :: 0 :: p) e

      | Equiv.Impl (f1, f2)
      | Equiv.And  (f1, f2)
      | Equiv.Or   (f1, f2) -> 
        sel_e_l sp ~projs ~vars ~conds ~p [f1; f2]

    and sel_e_l (sp : Sp.t) ~projs ~vars ~conds ~(p : pos) (l : Equiv.form list) = 
      List.foldi (fun i sp t -> sel_e sp ~projs ~vars ~conds ~p:(i :: p) t) sp l 
    in 

    sel_e Sp.empty ~projs:None ~vars:[] ~conds:[] ~p:[] t


  (*------------------------------------------------------------------*)
  type 'a f_map_fold =
    Term.term ->
    SE.arbitrary -> Vars.vars -> Term.term list -> pos ->
    'a ->
    'a * [`Map of Term.term | `Continue]

  type f_map =
    Term.term ->
    SE.arbitrary -> Vars.vars -> Term.term list -> pos -> 
    [`Map of Term.term | `Continue]

  type 'a f_fold =
    Term.term ->
    SE.arbitrary -> Vars.vars -> Term.term list -> pos ->
    'a ->
    'a
  (*------------------------------------------------------------------*)
  (* TODO: explicit system in terms: conds below may not be in the correct 
     system: they should be stated in [se] *)

  (** Internal *)
  let rec map_fold
      (func   : 'a f_map_fold) 
      (mode   : [`TopDown of bool | `BottomUp])
      (* - [`TopDown b]: apply [func] at top-level first, then recurse.
           [b] tells if we recurse under successful maps.
         - [`BottomUp _]: recurse, then apply [func] at top-level *)

      ~(se    : SE.arbitrary)      (* system expr applying the current pos. *)
      ~(vars  : Vars.var list)     (* variable bound above the current pos. *)
      ~(conds : Term.term list)    (* conditions above the current pos. *)
      ~(p     : pos)               (* current position *)
      ~(acc   : 'a)                (* folding value *)
      (ti     : Term.term)         
    : 'a * bool * Term.term        (* folding value, `Map found, term *)
    =
    let map_fold ~se ?(vars = vars) ?(conds = conds) = 
      map_fold func mode ~se ~vars ~conds 
    in
    let map_fold_l ~se ?(vars = vars) ?(conds = conds) =
      map_fold_l func mode ~se ~vars ~conds 
    in

    (* recurse strictly one level below *)
    let rec_strict_subterm ti acc =
      match ti with
      | Term.Fun (fs, _, [c;t;e]) when fs = Term.f_ite ->
        let conds_t =             c :: conds in
        let conds_e = Term.mk_not c :: conds in

        let acc, foundc, c = map_fold ~se ~conds         ~p:(0 :: p) ~acc c in
        let acc, foundt, t = map_fold ~se ~conds:conds_t ~p:(1 :: p) ~acc t in
        let acc, founde, e = map_fold ~se ~conds:conds_e ~p:(2 :: p) ~acc e in
        let found = foundc || foundt || founde in

        let ti' = Term.mk_ite ~simpl:false c t e in
        acc, found, if found then ti' else ti

      (* [φ => ψ] *)
      | Term.Fun (fs, fty, [t1; t2]) when fs = Symbols.fs_impl ->
        let conds2 = t1 :: conds in
        let acc, found1, t1 = 
          map_fold ~se ~conds        ~p:(0 :: p) ~acc t1
        in
        let acc, found2, t2 = 
          map_fold ~se ~conds:conds2 ~p:(1 :: p) ~acc t2
        in
        let found = found1 || found2 in

        let ti' = Term.mk_fun0 fs fty [t1; t2] in
        acc, found, if found then ti' else ti

      (* [φ && ψ] is handled as [φ && (φ => ψ)] *)
      | Term.Fun (fs, fty, [t1; t2]) when fs = Symbols.fs_and ->
        let conds2 = t1 :: conds in
        let acc, found1, t1 = 
          map_fold ~se ~conds        ~p:(0 :: p) ~acc t1
        in
        let acc, found2, t2 = 
          map_fold ~se ~conds:conds2 ~p:(1 :: p) ~acc t2
        in
        let found = found1 || found2 in

        let ti' = Term.mk_fun0 fs fty [t1; t2] in
        acc, found, if found then ti' else ti

      (* [φ || ψ] is handled as [φ || (¬ φ => ψ)] *)
      | Term.Fun (fs, fty, [t1; t2]) when fs = Symbols.fs_or ->
        let conds2 = (Term.mk_not t1) :: conds in

        let acc, found1, t1 = 
          map_fold ~se ~conds        ~p:(0 :: p) ~acc t1
        in
        let acc, found2, t2 = 
          map_fold ~se ~conds:conds2 ~p:(1 :: p) ~acc t2
        in
        let found = found1 || found2 in

        let ti' = Term.mk_fun0 fs fty [t1; t2] in
        acc, found, if found then ti' else ti

      (* [Fun _], general case *)
      | Term.Fun (fs, fty, l) ->
        let acc, found, l = map_fold_l ~se ~p ~acc l in

        let ti' = Term.mk_fun0 fs fty l in
        acc, found, if found then ti' else ti

      | Term.App (t1, l) ->
        let acc, found, t1_l = map_fold_l ~se ~p ~acc (t1 :: l) in

        let t1, l = List.takedrop 1 t1_l in
        let t1 = as_seq1 t1 in

        let ti' = Term.mk_app t1 l in
        acc, found, if found then ti' else ti


      | Term.Name (ns,l) ->
        let acc, found, l = map_fold_l ~se ~p ~acc l in

        let ti' = Term.mk_name ns l in
        acc, found, if found then ti' else ti

      | Term.Macro (ms, terms, ts) ->
        let l = terms @ [ts] in

        let acc, found, l = map_fold_l ~se ~vars ~conds ~p ~acc l in

        let l1, ts = List.takedrop (List.length terms) l in
        let ts = as_seq1 ts in

        let ti' = Term.mk_macro ms l1 ts in
        acc, found, if found then ti' else ti

      | Term.Action (a, l) ->
        let acc, found, l = map_fold_l ~se ~vars ~conds ~p ~acc l in

        let ti' = Term.mk_action a l in
        acc, found, if found then ti' else ti

      | Term.Var _ -> acc, false, ti

      | Term.Tuple l ->
        let acc, found, l = map_fold_l ~se ~vars ~conds ~p ~acc l in
        let ti' = Term.mk_tuple l in
        acc, found, if found then ti' else ti

      | Term.Proj (i,t) ->
        let acc, found, t = map_fold ~se ~vars ~conds ~p:(0 :: p) ~acc t in
        let ti' = Term.mk_proj i t in
        acc, found, if found then ti' else ti

      | Term.Quant (q, is, t0) -> 
        let is, subst = Term.refresh_vars is in
        let t0 = Term.subst subst t0 in
        let vars = List.rev_append is vars in

        let acc, found, t0 = map_fold ~se ~vars ~p:(0 :: p) ~acc t0 in

        let ti' = Term.mk_quant q is t0 in

        acc, found, if found then ti' else ti

      | Term.Diff (Explicit l) ->
        let acc, found, l' =
          map_fold_l ~se ~p ~acc ~projlabels:(List.map fst l) (List.map snd l)
        in
        let l = List.map2 (fun (lbl,_) t -> lbl,t) l l' in
        let ti' = Term.mk_diff l in
        acc, found, if found then ti' else ti

      | Term.Find (is, c, t, e) ->
        let is, subst = Term.refresh_vars is in
        let c = Term.subst subst c in
        let t = Term.subst subst t in

        let vars1 = List.rev_append is vars in

        let conds_t = c :: conds in 
        let conds_e = Term.mk_forall is (Term.mk_not c) :: conds in

        let acc, foundc, c = 
          map_fold ~se ~vars:vars1 ~conds         ~p:(0 :: p) ~acc c 
        in
        let acc, foundt, t = 
          map_fold ~se ~vars:vars1 ~conds:conds_t ~p:(1 :: p) ~acc t 
        in
        let acc, founde, e = 
          map_fold ~se ~vars       ~conds:conds_e ~p:(2 :: p) ~acc e 
        in
        let found = foundc || foundt || founde in

        let ti' = Term.mk_find is c t e in
        acc, found, if found then ti' else ti
    in

    match mode with
    | `TopDown b ->
      begin
        match func ti se vars conds p acc with
        | acc, `Map t -> 
          if b then
            let acc, _, t = map_fold ~se ~p ~acc:acc t in
            acc, true, t
          else
            acc, true, t

        | acc, `Continue -> rec_strict_subterm ti acc
      end

    | `BottomUp ->
      let acc, found, ti = rec_strict_subterm ti acc in
      match func ti se vars conds p acc with
      | acc, `Map ti   -> acc, true,  ti
      | acc, `Continue -> acc, found, ti


  and map_fold_l
      func mode      
      ~se ~vars ~conds ~(p : pos) ~acc
      ?projlabels            (* optional list of projection labels *)
      (l : Term.terms)
    =
    let (acc, found), l =
      List.mapi_fold (fun i (acc, found) ti ->
          let se = match projlabels with
            | None -> se
            | Some labels -> SE.project [List.nth labels i] se
          in
          let acc, found', ti =
            map_fold func mode ~se ~vars ~conds ~p:(i :: p) ~acc ti
          in
          (acc, found || found'), ti
        ) (acc, false) l 
    in
    acc, found, l

  (*------------------------------------------------------------------*)
  (** Internal *)
  let rec map_fold_e
      (func   : 'a f_map_fold) 
      (mode   : [`TopDown of bool | `BottomUp])
      (* - [`TopDown b]: apply [func] at top-level first, then recurse.
           [b] tells if we recurse under successful maps.
         - [`BottomUp _]: recurse, then apply [func] at top-level *)

      ~(system : SE.context)    (* context applying the current pos. *)
      ~(vars   : Vars.vars)     (* variable bound above the current position *)
      ~(conds  : Term.terms)    (* conditions above the current position *)
      ~(p      : pos)           (* current position *)
      ~(acc    : 'a)            (* folding value *)
      (ti      : Equiv.form)       
    : 'a * bool * Equiv.form    (* folding value, `Map found, term *)
    = 
    let map_fold_e ?(system = system) ?(vars = vars) ?(conds = conds) = 
      map_fold_e func mode ~system ~vars ~conds 
    in
    let map_fold_e_l ?(system = system) ?(vars = vars) ?(conds = conds) = 
      map_fold_e_l func mode ~system ~vars ~conds 
    in

    match ti with
    | Equiv.Quant (q, is, t0) ->
      let is, subst = Term.refresh_vars_w_info is in
      let t0 = Equiv.subst subst t0 in
      let vars = List.rev_append (List.map fst is) vars in
      (* FEATURE: add tags in Fold.map *)

      let acc, found, t0 = map_fold_e ~vars ~p:(0 :: p) ~acc t0 in

      let ti' = Equiv.mk_quant_tagged q is t0 in
      acc, found, if found then ti' else ti

    | Equiv.Atom (Reach t) -> 
      let se = system.set in
      let acc, found, t =
        map_fold func mode ~se ~vars ~conds ~p:(0 :: 0 :: p) ~acc t 
      in
      let ti' = Equiv.Atom (Reach t) in
      acc, found, if found then ti' else ti

    | Equiv.Atom (Equiv e) -> 
      let se = (oget system.pair :> SE.arbitrary) in
      let acc, found, l = 
        map_fold_l func mode ~se ~vars ~conds ~p:(0 :: 0 :: p) ~acc e 
      in
      let ti' = Equiv.Atom (Equiv l) in
      acc, found, if found then ti' else ti

    | Equiv.Impl (f1, f2)
    | Equiv.And  (f1, f2)
    | Equiv.Or   (f1, f2) -> 
      let acc, found, l = map_fold_e_l ~vars ~conds ~p ~acc [f1; f2] in
      let f1, f2 = as_seq2 l in
      let ti' = 
        match ti with
        | Equiv.Impl _ -> Equiv.Impl (f1, f2)
        | Equiv.And  _ -> Equiv.And  (f1, f2)
        | Equiv.Or   _ -> Equiv.Or   (f1, f2)
        | _ -> assert false
      in
      acc, found, if found then ti' else ti

  and map_fold_e_l func mode ~system ~vars ~conds ~p ~acc (l : Equiv.form list) =
    let (acc, found), l =
      List.mapi_fold (fun i (acc, found) ti -> 
          let acc, found', ti = 
            map_fold_e func mode ~system ~vars ~conds ~p:(i :: p) ~acc ti
          in
          (acc, found || found'), ti
        ) (acc, false) l 
    in
    acc, found, l


  (*------------------------------------------------------------------*)
  (** Exported *)
  let map
      ?(mode=`TopDown false) (func : f_map)
      (se : SE.arbitrary) (t : Term.term)
    : bool * Term.term
    =
    let func : unit f_map_fold = 
      fun t projs vars conds p () -> (), func t projs vars conds p 
    in
    let (), found, t =
      map_fold func mode ~se ~vars:[] ~conds:[] ~p:[] ~acc:() t
    in
    found, t

  (** Exported *)
  let map_e
      ?(mode=`TopDown false) (func : f_map)
      (system : SE.context) (t : Equiv.form)
    : bool * Equiv.form
    =
    let func : unit f_map_fold = 
      fun t projs vars conds p () -> (), func t projs vars conds p 
    in
    let (), found, t = 
      map_fold_e func mode ~system ~vars:[] ~conds:[] ~p:[] ~acc:() t
    in
    found, t

  (*------------------------------------------------------------------*)
  (** Exported *)
  let fold
      ?(mode=`TopDown false) 
      (func : 'a f_fold)
      (se : SE.arbitrary) 
      (acc : 'a) (t : Term.term) 
    =
    let f:'a f_map_fold =
      fun t se v ts p acc -> (func t se v ts p acc, `Continue)
    in
    let a, _, _ = map_fold f mode ~se ~vars:[] ~conds:[] ~p:[] ~acc t in
    a

  (** Exported *)
  let fold_e 
      ?(mode=`TopDown false) 
      (func : 'a f_fold)
      (system : SE.context) 
      (acc : 'a) (t : Equiv.form) 
    =
    let f:'a f_map_fold =
      fun t se v ts p acc -> (func t se v ts p acc, `Continue)
    in   
    let a, _, _ = map_fold_e f mode ~system ~vars:[] ~conds:[] ~p:[] ~acc t in
    a
  (*------------------------------------------------------------------*)
  (** Exported *)
  let fold_shallow
      (func : 'a f_fold)
      ~(se : SE.arbitrary)
      ~(fv:Vars.vars)
      ~(cond:Term.terms)
      ~(p:pos)
      (acc : 'a) (t : Term.term) 
    =
    let f tt se v c p acc =
      if tt = t then
        acc, `Continue
      else
        func tt se v c p acc, `Map tt
    in
    let a, _, _ = map_fold f (`TopDown false) ~se ~vars:fv ~conds:cond ~p ~acc t in
    a 

  (*------------------------------------------------------------------*)
  (** Exported *)
  let map_fold
      ?(mode=`TopDown false) 
      (func : 'a f_map_fold)
      (se : SE.arbitrary) 
      (acc : 'a) (t : Term.term) 
    =
    map_fold func mode ~se ~vars:[] ~conds:[] ~p:[] ~acc t

  (** Exported *)
  let map_fold_e 
      ?(mode=`TopDown false) 
      (func : 'a f_map_fold)
      (system : SE.context) 
      (acc : 'a) (t : Equiv.form) 
    =
    map_fold_e func mode ~system ~vars:[] ~conds:[] ~p:[] ~acc t
end

(*------------------------------------------------------------------*)
(** {2 Matching variable assignment} *)

module Mvar : sig[@warning "-32"]
  type t
  val empty : t

  (** union of two [mv] with disjoint supports *)
  val union : t -> t -> t

  (** remove a variable assignment *)
  val remove : Vars.var -> t -> t

  (** Add a variable assignment. 
      The system indicate how to interpret the assignment. *)
  val add : Vars.tagged_var -> SE.t -> Term.term -> t -> t

  (** check if a variable is assigned *)
  val mem : Vars.var -> t -> bool

  val find : Vars.var -> t -> Term.term

  val is_empty : t -> bool

  val filter : (Vars.var -> (Vars.Tag.t * SE.t * Term.term) -> bool) -> t -> t

  val map : (Term.term -> Term.term) -> t -> t

  val mapi : (Vars.var -> SE.t -> Term.term -> Term.term) -> t -> t

  val fold :
    (Vars.var -> (Vars.Tag.t * SE.t * Term.term) -> 'b -> 'b) -> t -> 'b -> 'b

  (** [table] and [env] are necessary to check that restrictions on 
      variables instanciation have been respected. *)
  val to_subst :
    mode:[`Match|`Unif] ->
    Symbols.table -> Vars.env ->
    t ->
    [`Subst of Term.subst | `BadInst of Format.formatter -> unit]

  (** [to_subst] when all matched (or unified) variables are unrestricted 
      variables (i.e. local variables).
      Indeed, in that case the substitution resolution cannot fail. *)
  val to_subst_locals :
    mode:[`Match|`Unif] -> t -> Term.subst

  val pp : Format.formatter -> t -> unit
end = struct
  (** [id] is a unique identifier used to do memoisation. *)
  type t = {
    id    : int;
    subst : (Vars.Tag.t * SE.t * term) Mv.t;
    (* TODO: checks on the systems when doing assignments etc *)
  }

  let cpt = ref 0
  let make subst = incr cpt; { id = !cpt; subst }

  let pp fmt (mv : t) : unit =
    let pp_binding fmt (v, (tag,system,t)) =
      Fmt.pf fmt "@[%a[%a]{%a} → %a@]"
        Vars.pp v Vars.Tag.pp tag SE.pp system Term.pp t 
    in
    Fmt.pf fmt "@[<v 2>{id:%d@;%a}@]" mv.id
      (Fmt.list ~sep:Fmt.cut pp_binding) (Mv.bindings mv.subst)

  let empty = make Mv.empty

  let union mv1 mv2 =
    make (Mv.union (fun _ _ _ -> assert false) mv1.subst mv2.subst)

  let add ((v,tag) : Vars.tagged_var) (system : SE.t) (t : term) (m : t) : t =
    make (Mv.add v (tag,system,t) m.subst)

  let remove (v : Vars.var) (m : t) : t =
    make (Mv.remove v m.subst)

  let mem (v : Vars.var) (m : t) : bool = Mv.mem v m.subst

  let find (v : Vars.var) (m : t) =
    let _, _, t = Mv.find v m.subst in
    t

  let is_empty (m : t) = Mv.is_empty m.subst

  (* FIXME: check that forgetting variables does not modify the variable 
     assigment for the other variables. *)
  let filter f (m : t) : t = make (Mv.filter f m.subst)

  let map (f : Term.term -> Term.term) (m : t) : t =
    make (Mv.map (fun (tag,system,t) -> tag, system, f t) m.subst)

  let mapi f (m : t) : t =
    make (Mv.mapi (fun i (tag, system, t) -> tag, system, f i system t) m.subst)

  let fold f (m : t) (init : 'b) : 'b = Mv.fold f m.subst init

  let to_subst
      ~(mode:[`Match|`Unif])
      (table : Symbols.table) (env : Vars.env)
      (mv : t)
    : [`Subst of Term.subst | `BadInst of Format.formatter -> unit]
    =
    let check_subst (subst : Term.subst) =
      let bad_instanciations =
        (* check that the instanciation of [v], which has tag [tag], 
           by [t] is correct *)
        List.filter (fun (v,(tag, system, _)) ->
            let t = Term.subst subst (Term.mk_var v) in
            let sys_cntxt = SE.{ set = system; pair = None; } in
            let env = Env.init ~table ~vars:env ~system:sys_cntxt () in

            (tag.Vars.Tag.system_indep &&
             not (HighTerm.is_system_indep env t)) ||
            (tag.Vars.Tag.const &&
             not (HighTerm.is_constant `Exact env t))
          ) (Mv.bindings mv.subst)
      in
      if bad_instanciations = [] then
        `Subst subst
      else
        let pp_err fmt =
          Fmt.pf fmt "@[<hv 2>bad variable instanciation(s):@;@[<v>%a@]@]"
            (Fmt.list ~sep:Fmt.cut
               (fun fmt (v,(tag,_system,_)) ->
                  Fmt.pf fmt "@[%a@] -> @[%a@]"
                    Vars.pp_typed_tagged_list [v,tag]
                    Term.pp (Term.subst subst (Term.mk_var v))
               )
            )
            bad_instanciations
        in
        `BadInst pp_err
    in

    let s =
      Mv.fold (fun v (_tag,_system,t) subst ->
          match v, t with
          | v, t ->
            ESubst (mk_var v, t) :: subst
        ) mv.subst []
    in

    match mode with
    | `Match -> check_subst s
    | `Unif ->
      (* We need to substitute until we reach a fixpoint *)
      let support = Mv.fold (fun v _ supp -> Sv.add v supp) mv.subst Sv.empty in
      let rec fp_subst (t : term) : term =
        if Sv.disjoint (fv t) support then t
        else fp_subst (subst s t)
      in
      let s = List.map (fun (ESubst (v, t)) -> ESubst (v, fp_subst t)) s in
      check_subst s

  let to_subst_locals ~(mode:[`Match|`Unif]) (mv : t) : Term.subst =
    match
      to_subst ~mode
        Symbols.builtins_table    (* default value, which won't be used *)
        Vars.empty_env            (* idem *)
        mv
    with
    | `Subst s -> s
    | `BadInst pp_err ->
      Fmt.epr "%t@." pp_err;
      assert false (* cannot happen for unrestricted variables *)

  (* [to_subst_locals] with memoisation *)
  let to_subst_locals =
    let module H1 = struct
      type _t = t
      type t = _t
      let hash t = t.id
      let equal t t' = t.id = t'.id
    end in
    let module H2 = struct
      type t = [`Match|`Unif]
      let hash = function `Match -> 1 | `Unif -> 0
      let equal x y = x = y
    end in
    let module Memo = Ephemeron.K2.Make (H1) (H2) in
    let memo = Memo.create 256 in
    fun ~mode t ->
      try Memo.find memo (t,mode) with
      | Not_found ->
        let r = to_subst_locals ~mode t in
        Memo.add memo (t,mode) r;
        r

end


(*------------------------------------------------------------------*)
(** {2 Matching information for error messages} *)

(** update with the greatest value, where [MR_failed > MR_check_st > MR_ok] *)
let minfos_update new_v old_v =
  match old_v with
  | None -> Some new_v
  | Some old_v ->
    match new_v, old_v with
    | _, MR_failed | MR_failed, _ -> Some MR_failed

    | MR_check_st t1, MR_check_st _t2 ->
      (* They may not be equal, but are alpha-equal *)
      (* assert (List.for_all2 (=) t1 t2); *)
      Some (MR_check_st t1)

    | MR_ok, MR_check_st t | MR_check_st t, MR_ok ->
      Some (MR_check_st t)

    | MR_ok, MR_ok -> Some MR_ok

let minfos_ok (term : Term.term) (minfos : match_infos) : match_infos =
  Mt.update term (minfos_update MR_ok) minfos

let minfos_failed (term : Term.term) (minfos : match_infos) : match_infos =
  Mt.update term (minfos_update MR_failed) minfos

let minfos_check_st
    (term : Term.term)
    (st   : Term.term list)
    (minfos : match_infos)
  : match_infos
  =
  Mt.update term (minfos_update (MR_check_st st)) minfos

(*------------------------------------------------------------------*)
(** Normalize a match information map, by making a term tagged
    [MR_check_st] only if:
    -     at least one of its subterms is tagged [MR_ok]
    - and at least one of its subterms is tagged [MR_fail]. *)
let minfos_norm (minit : match_infos) : match_infos =
  let rec norm t mfinal : match_info * match_infos =
    if Mt.mem t mfinal
    then Mt.find t mfinal, mfinal
    else match Mt.find t minit with
      | MR_ok | MR_failed as r -> r, Mt.add t r mfinal
      | MR_check_st st ->
        let infos, mfinal =
          List.fold_left (fun (infos, mfinal) t ->
              let i, mfinal = norm t mfinal in
              i :: infos, mfinal
            ) ([], mfinal) st
        in
        (* special case for binders, because alpha-renamed subterms
           cannot be checked later *)
        (* FEATURE: fix it to have an improved printing *)
        if List.for_all (fun x -> x = MR_ok) infos
        then MR_ok, Mt.add t MR_ok mfinal
        else if Term.is_binder t
        then MR_failed, Mt.add t MR_failed mfinal
        else MR_check_st st, Mt.add t (MR_check_st st) mfinal
  in

  Mt.fold (fun et _ mfinal ->
      let _, mfinal = norm et mfinal in
      mfinal) minit Mt.empty

(*------------------------------------------------------------------*)
(** Exception raised when unification or matching fails.
    Remark that the [match_infos] are only meaningful for failed 
    matching (not unification). *)
exception NoMatch of (term list * match_infos) option

let no_unif ?infos () = raise (NoMatch infos)

(*------------------------------------------------------------------*)
(** {2 Reduction utilities} *)

(** Expand once at head position. 
    Throw [exn] in case of failure. *)
let expand_head_once
    ~(exn : exn) 
    ~(mode : Macros.expand_context)
    (table : Symbols.table) (sexpr : SE.t) 
    (hyps : Hyps.TraceHyps.hyps Lazy.t)
    (t : Term.term) 
  : Term.term * bool 
  = 
  let models = (* evaluates the models only if needed *)
    lazy (
      let lits = Hyps.TraceHyps.fold (fun _ f acc ->
          match f with
          | Local f
          | Global Equiv.(Atom (Reach f)) -> f :: acc
          | Global _ -> acc
        ) (Lazy.force hyps) [] 
      in
      Constr.models_conjunct (TConfig.solver_timeout table) ~exn lits)
  in 
  let cntxt () = 
    let se = try SE.to_fset sexpr with SE.Error _ -> raise exn in
    Constr.{ 
      table; system = se; 
      models = Some (Lazy.force models);
    } in
  match t with
  | Term.Macro (ms, l, ts) ->

    if Constr.query ~precise:true (Lazy.force models) [`Pos, Happens ts] then
      match Macros.get_definition ~mode (cntxt ()) ms ~args:l ~ts with
      | `Def mdef -> mdef, true
      | _ -> raise exn 
    else raise exn 

  | Fun (fs, _, ts) 
    when Operator.is_operator table fs -> 
    begin
      match Operator.unfold table sexpr fs ts with
      | `Ok t -> t, true
      | `FreeTyv -> raise exn
    end

  | _ -> raise exn


(* projection reduction *)
let reduce_proj (t : Term.term) : Term.term * bool =
  match t with
  | Term.Proj (i, t) ->
    begin
      match t with
      | Term.Tuple ts -> List.nth ts (i - 1), true
      | _ -> t, false
    end

  | _ -> t, false

(* β-reduction *)
let reduce_beta (t : Term.term) : Term.term * bool =
  match t with
  | Term.App (t, arg :: args) -> 
    begin
      match t with
      | Term.Quant (Term.Lambda, v :: evs, t0) ->
        let evs, subst = Term.refresh_vars evs in
        let t0 = Term.subst (Term.ESubst (Term.mk_var v, arg) :: subst) t0 in

        Term.mk_app (Term.mk_lambda evs t0) args, true

      | _ -> Term.mk_app t (arg :: args), false
    end 

  | _ -> t, false

(*------------------------------------------------------------------*)
(** {2 Matching and unification internal states} *)

(** (Descending) state used during matching or unification. *)
type unif_state = {
  mode : [`Match | `Unif];

  mv  : Mvar.t;           (** inferred variable assignment *)
  bvs : Vars.tagged_vars; (** bound variables "above" the current position *)

  subst_vs : Sv.t;
  (** vars already substituted (for cycle detection during unification) *)

  support : Vars.tagged_vars; (** free variable which we are trying to match *)
  env     : Vars.env;         (** rigid free variables (disjoint from [support]) *)

  expand_context : Macros.expand_context; 
  (** expantion mode for macros. See [Macros.expand_context]. *)

  ty_env  : Type.Infer.env;
  table   : Symbols.table;
  system  : SE.context; (** system context applying at the current position *)

  hyps : Hyps.TraceHyps.hyps Lazy.t;

  use_fadup     : bool;
  allow_capture : bool;
}

(*------------------------------------------------------------------*)
let env_of_unif_state (st : unif_state) : Env.t =
  let vars = Vars.add_vars st.bvs st.env in
  Env.init ~table:st.table ~vars ~system:st.system () 

(*------------------------------------------------------------------*)
(** {2 Module signature of matching} *)

type match_res =
  | FreeTyv
  | NoMatch of (terms * match_infos) option
  | Match   of Mvar.t

(** unification algorithm options *)
type match_option = {
  mode          : [`Eq | `EntailLR | `EntailRL];
  use_fadup     : bool;
  allow_capture : bool;
  (** allow pattern variables to capture bound variables (i.e. to be
      instantiated by terms using bound variables). 
      When doing rewriting, lemma application, etc, must be false. *)
}

let default_match_option = { 
  mode           = `Eq; 
  use_fadup      = false; 
  allow_capture  = false; 
}

(** Module signature of matching.
    The type of term we match into is abstract. *)
module type S = sig
  type t

  val pp_pat :
    (Format.formatter -> 'a -> unit) ->
    Format.formatter -> 'a pat -> unit

  val try_match :
    ?option:match_option ->
    ?mv:Mvar.t ->
    ?env:Vars.env ->
    ?ty_env:Type.Infer.env ->
    ?hyps:Hyps.TraceHyps.hyps Lazy.t ->
    ?expand_context:Macros.expand_context ->
    Symbols.table ->
    SE.context ->
    t -> 
    t pat ->
    match_res

  val find : 
    ?option:match_option ->
    Symbols.table ->
    SE.context ->
    (Term.term pat) -> 
    t -> 
    Term.term list
end

(*------------------------------------------------------------------*)
(** {2 Matching and unification} *)

(** Exported 
    Generic matching (or unification) function, built upon [Term.term] or [Equiv.form] 
    matching (or unification). *)
let unif_gen (type a)
    (f_kind  : a Equiv.f_kind)
    (ut_mode : [`Unif | `Match])
    (fmatch  : 
       mode:[`Contravar | `Covar | `Eq] -> a -> a -> unif_state -> Mvar.t) 
    ?(option=default_match_option)
    ?(mv     : Mvar.t option)
    ?(env    : Vars.env option)
    ?(ty_env : Type.Infer.env option)
    ?(hyps   : Hyps.TraceHyps.hyps Lazy.t = lazy (Hyps.TraceHyps.empty))
    ?(expand_context : Macros.expand_context = InSequent)
    (table   : Symbols.table)
    (system  : SE.context)
    (t1      : a pat)
    (t2      : a pat) 
  : match_res
  =
  (* [must_close] state if [ty_env] must be closed at the end of 
     the matching *)
  let must_close, ty_env = match ty_env with
    | Some e -> false, e
    | None   -> true,  Type.Infer.mk_env () 
  in

  let univars1, ty_subst1 = Type.Infer.open_tvars ty_env t1.pat_tyvars in
  let term1 = Equiv.Babel.tsubst f_kind ty_subst1 t1.pat_term in

  let univars2, ty_subst2 = Type.Infer.open_tvars ty_env t2.pat_tyvars in
  let term2 = Equiv.Babel.tsubst f_kind ty_subst2 t2.pat_term in

  (* substitute back the univars by the corresponding tvars *)
  let ty_subst_rev : Type.tsubst =
    let tysubst =
      List.fold_left2 (fun s tv tu ->
          Type.tsubst_add_univar s tu (Type.TVar tv)
        ) Type.tsubst_empty t1.pat_tyvars univars1
    in
    List.fold_left2 (fun s tv tu ->
        Type.tsubst_add_univar s tu (Type.TVar tv)
      ) tysubst t2.pat_tyvars univars2
  in

  let supp1 = List.map (fun (v,t) -> Vars.tsubst ty_subst1 v, t) t1.pat_vars in
  let supp2 = List.map (fun (v,t) -> Vars.tsubst ty_subst2 v, t) t2.pat_vars in

  assert (
    Sv.disjoint
      (Sv.of_list (List.map fst supp1))
      (Sv.of_list (List.map fst supp2)));

  let support = supp1 @ supp2 in

  (* environment, with all variables *)
  let env =
    match env with
    | None ->
      Vars.of_list @@
      Vars.Tag.global_vars @@
      Sv.elements @@
      (Sv.union (Equiv.Babel.fv f_kind term1) (Equiv.Babel.fv f_kind term2))
      
    | Some env -> env
  in
  (* we remove support from [env] *)
  let env =
    List.fold_left (fun env v ->
        if Vars.mem env v then Vars.rm_var v env else env
      ) env (List.map fst support)
  in

  let mv_init = odflt Mvar.empty mv in
  let st_init : unif_state = {
    mode = ut_mode;
    bvs = [];
    mv = mv_init;

    subst_vs = Sv.empty;

    expand_context;

    table; system; env; support; ty_env; hyps;

    use_fadup     = option.use_fadup;
    allow_capture = option.allow_capture; 
  } in

  (* Term matching ignores [mode]. Matching in [Equiv] does not. *)
  let mode =
    if ut_mode = `Unif then `Eq
    else
      match option.mode with
      | `Eq -> `Eq
      | `EntailRL -> `Covar
      | `EntailLR -> `Contravar
  in

  try
    let mv = fmatch ~mode term1 term2 st_init in

    if not must_close then 
      Match mv 
    else if not (Type.Infer.is_closed ty_env) then 
      FreeTyv
    else
      (* FIXME: shouldn't we substitute type variables in Mv co-domain ? *)
      let mv =
        Mvar.fold (fun v (tag,system,t) mv ->
            let v = Vars.tsubst ty_subst_rev v in
            Mvar.add (v,tag) system t mv
          ) mv Mvar.empty
      in
      Match mv

  with
  | NoMatch minfos -> NoMatch minfos

(*------------------------------------------------------------------*)
(** {3 Term matching and unification} *)

module T (* : S with type t = Term.term *) = struct
  type t = term

  let pp_pat pp_t fmt p =
    Fmt.pf fmt "@[<hov 0>{term = @[%a@];@ tyvars = @[%a@];@ vars = @[%a@]}@]"
      pp_t p.pat_term
      (Fmt.list ~sep:Fmt.sp Type.pp_tvar) p.pat_tyvars
      Vars.pp_typed_tagged_list p.pat_vars

  (*------------------------------------------------------------------*)
  let is_bvs (st : unif_state) = function
    | Var v0' -> List.mem_assoc v0' st.bvs
    | _ -> false

  (*------------------------------------------------------------------*)
  (* Invariants:
     - [st.mv] supports in included in [p.pat_vars].
     - [st.bvs] is the set of variables bound above [t].
     - [st.bvs] must be disjoint from the free variables of the terms in the
       co-domain of [mv]. *)
  let rec tunif (t : term) (pat : term) (st : unif_state) : Mvar.t =
    match t, pat with
    | _, Var v' when st.mode = `Match -> vmatch t v' st

    | Var v, t | t, Var v when st.mode = `Unif -> vunif t v st

    | Tuple l, Tuple l' ->
      if List.length l <> List.length l' then no_unif ();
      tunif_l l l' st

    | Proj (i,t), Proj (i',t') when i = i' ->
      tunif t t' st

    | _, App(f', l') ->
      assert (l' <> []);
      begin
        match t with
        | App (f, l) when List.length l = List.length l' ->
          begin
            try tunif_l (f :: l) (f' :: l') st with
            | NoMatch _ -> tunif_eta_expand st t (f', l')
          end

        | _ -> tunif_eta_expand st t (f', l')
      end

    | Fun (fn , fty, terms), Fun (fn', fty', terms') when fn = fn' ->
      assert (fty = fty');

      if List.length terms = List.length terms' then 
        tunif_l terms terms' st
      else no_unif ()

    | Name (s,l), Name (s',l') when s = s' ->
      assert (List.length l = List.length l');

      tunif_l l l' st 

    | Macro (s, terms, ts),
      Macro (s', terms', ts') when s.s_symb = s'.s_symb ->
      assert (Type.equal s.s_typ s'.s_typ && List.length terms = List.length terms');

      let mv = tunif_l terms terms' st in
      tunif ts ts' { st with mv }

    | Action (s,is), Action (s',is') when s = s' -> 
      tunif_l is is' st

    | Diff (Explicit l), Diff (Explicit l') ->
      if List.length l <> List.length l' then no_unif ();

      List.fold_left2 (fun mv (lt,t) (lpat, pat) ->
          if lt <> lpat then no_unif ();

          tunif t pat { st with mv; system = SE.project_set [lt] st.system }
        ) st.mv l l'

    | Find (is, c, t, e), Find (is', pat_c, pat_t, pat_e) ->
      let s, s', st = unif_bnds is is' st in

      let c    ,     t = subst s      c, subst s      t
      and pat_c, pat_t = subst s' pat_c, subst s' pat_t in
      tunif_l [c; t; e] [pat_c; pat_t; pat_e] st

    | Quant (q, vs,t), Quant (q', vs', pat) when q = q' ->
      let s, s', st = unif_bnds vs vs' st in
      let t   = subst s    t in
      let pat = subst s' pat in
      tunif t pat st

    | _, _ -> try_reduce_head1 t pat st

  (* Try to match [t] with [(f' l')].
     Use a higher-order matching heuristic When [f'] is a variable
     to be inferred (i.e. [f' ∈ st.support]) and [l'] are all
     bound variables, as follows:
     - generalize [l'] in [t] as [tgen]
         [tgen := (λvₗ ↦ t{l' → vₗ}) l']
     - matches [tgen] and [(f' l')] *)
  and tunif_eta_expand
      (st : unif_state) (t : term) ((f', l') : term * term list)
    =
    if not (List.for_all (is_bvs st) l')
    then try_reduce_head1 t (Term.mk_app f' l') st
    else
      match f' with  
      | Var v' when List.mem_assoc v' st.support ->
        (* vₗ *)
        let v_fresh_l' = 
          List.map (fun t_v -> Vars.make_fresh (Term.ty t_v) "y") l'
        in

        (* [t_body = t{l' → vₗ}] *)
        let t_body =
          Term.subst (List.map2 (fun v_0 t_v0 ->
              Term.ESubst (t_v0, Term.mk_var v_0)
            ) v_fresh_l' l')
            t
        in

        (* Match
             [(λvₗ ↦ t{l' → vₗ}) l'] and [(f' l')]
           by simply matching the bodies
             [λvₗ ↦ t{l' → vₗ}] and [f'] *)
        tunif
          (Term.mk_lambda ~simpl:false v_fresh_l' t_body)
          f' st

      | _ -> try_reduce_head1 t (Term.mk_app f' l') st


  and m_expand_head_once (st : unif_state) (t : term) : term * bool =
    expand_head_once
      ~mode:st.expand_context ~exn:(NoMatch None) 
      st.table st.system.set st.hyps t 

  (* try to reduce one step at head position in [t] or [pat], 
     and resume matching *)
  and try_reduce_head1 (t : term) (pat : term) (st : unif_state) : Mvar.t =
    match t, pat with
    (* delta-reduction *)
    | (Macro _ | Fun _), (Macro _ | Fun _) ->      
      let t, t_red = m_expand_head_once st t in

      if t_red then tunif t pat st 
      else
        let pat, pat_red = m_expand_head_once st pat in
        if pat_red then tunif t pat st
        else no_unif ()

    | Macro _, _ | Fun _, _ -> 
      let t, t_red = m_expand_head_once st t in
      if t_red then tunif t pat st
      else no_unif ()

    | _, Macro _ | _, Fun _ -> 
      let pat, pat_red = m_expand_head_once st pat in
      if pat_red then tunif t pat st
      else no_unif ()

    (* projection reduction *)
    | Proj _, Proj _ ->
      let t, t_red = reduce_proj t in
      if t_red then tunif t pat st
      else 
        let pat, pat_red = reduce_proj pat in
        if pat_red then tunif t pat st
        else no_unif ()

    | Proj _, _ ->
      let t, t_red = reduce_proj t in
      if t_red then tunif t pat st
      else no_unif ()

    | _, Proj _ ->
      let pat, pat_red = reduce_proj pat in
      if pat_red then tunif t pat st
      else no_unif ()

    (* other *)
    | Var _, _ -> no_unif ()   (* FEATURE *)
    | _, Var v when not (List.mem_assoc v st.support) -> no_unif () (* FEATURE *)
    | _ -> no_unif ()

  (* Return: left subst, right subst, match state *)
  and unif_bnds
      (vs : Vars.vars) (vs' : Vars.vars) (st : unif_state)
    : esubst list * esubst list * unif_state
    =
    unif_tagged_bnds (Vars.Tag.local_vars vs) (Vars.Tag.local_vars vs') st
      
  and unif_tagged_bnds
      (vs : Vars.tagged_vars) (vs' : Vars.tagged_vars) (st : unif_state)
    : esubst list * esubst list * unif_state
    =
    if List.length vs <> List.length vs' then
      no_unif ();

    (* check that types and tags are compatible *)
    List.iter2 (fun (v,tag) (v',tag') ->
        let ty, ty' = Vars.ty v, Vars.ty v' in

        if tag <> tag' then no_unif ();
        
        if Type.Infer.unify_eq st.ty_env ty ty' = `Fail then
          no_unif ();
      ) vs vs';

    (* refresh [vs] *)
    let vs, s = refresh_vars_w_info vs in

    (* refresh [vs'] using the same renaming *)
    let s' = List.map2 (fun (ESubst (_, new_v)) (v',_) ->
        ESubst (mk_var v', new_v)
      ) (List.rev s)          (* reversed ! *)
        vs'
    in

    (* update [bvs] *)
    let st = { st with bvs = vs @ st.bvs } in

    s, s', st
    
    
  and tunif_l (tl : terms) (patl : terms) (st : unif_state) : Mvar.t =
    List.fold_left2 (fun mv t pat ->
        tunif t pat { st with mv }
      ) st.mv tl patl

  (* unify a variable and a term. *)
  and vunif (t : term) (v : Vars.var) (st : unif_state) : Mvar.t =
    let v, t = match t with
      | Var v' ->
        if not (List.mem_assoc v st.support) then
          v', mk_var v
        else if not (List.mem_assoc v' st.support) then
          v, t
        else if Vars.compare v v' < 0 then
          v, t
        else
          v', mk_var v

      | _ -> v, t
    in
    if t = mk_var v then
      st.mv

    else match List.assoc_opt v st.support with
      | None -> no_unif ()

      | Some tag ->
        (* [v] in the support with tag [tag], and [v] smaller than [v'] if [t = Var v'] *)
        match Mvar.find v st.mv with
        (* first time we see [v]: store the substitution and add the
           type information. *)
        | exception Not_found ->
          if Type.Infer.unify_eq st.ty_env (ty t) (Vars.ty v) = `Fail then
            no_unif ();

          (* When [st.allow_capture] is false (which is the default), check that we
           are not trying to unify [v] with a term bound variables. *)
          if not (Sv.disjoint (fv t) (Sv.of_list (List.map fst st.bvs))) &&
             not st.allow_capture then
            no_unif ();

          (Mvar.add (v, tag) st.system.set t st.mv)

        (* If we already saw the variable, check that there is no cycle, and
           call back [unif]. *)
        | t' -> 
          if Sv.mem v st.subst_vs then no_unif ()
          else
            let st =
              { st with subst_vs = Sv.add v st.subst_vs }
            in
            tunif t t' st

  (* Match a variable of the pattern with a term. *)
  and vmatch (t : term) (v : Vars.var) (st : unif_state) : Mvar.t =
    match List.assoc_opt v st.support with
    | None -> (* [v] not in the pattern *)
      (* FEATURE: conversion *)
      if t <> mk_var v then try_reduce_head1 t (mk_var v) st else st.mv

    | Some tag -> (* [v] in the pattern, with tag [tag] *)
      match Mvar.find v st.mv with
      (* If this is the first time we see the variable, store the subterm
         and add the type information. *)
      | exception Not_found ->
        if Type.Infer.unify_eq st.ty_env (ty t) (Vars.ty v) = `Fail then
          no_unif ();

        (* When [st.allow_capture] is false (which is the default), check that we
           are not trying to match [v] with a term bound variables. *)
        if not (Sv.disjoint (fv t) (Sv.of_list (List.map fst st.bvs))) &&
           not st.allow_capture then 
          no_unif ();

        Mvar.add (v, tag) st.system.set t st.mv

      (* If we already saw the variable, check that the subterms are
         identical. *)
      | t' -> 
        (* FEATURE: conversion *)
        if not (Term.alpha_conv t t') then no_unif () else st.mv

  (*------------------------------------------------------------------*)
  (** Exported.
      Remark: term matching ignores [mode]. *)
  let try_match
      ?option ?mv ?env ?ty_env ?hyps ?expand_context
      (table   : Symbols.table)
      (system  : SE.context)
      (t1      : Term.term)
      (t2      : Term.term pat) 
    =
    unif_gen
      Equiv.Local_t `Match
      (fun[@warning "-27"] ~mode -> tunif)

      (* repeat arguments, wrapping [t1] in a pattern *)
      ?option ?mv ?env ?ty_env ?hyps ?expand_context
      table system
      Term.{ pat_term = t1; pat_vars = []; pat_tyvars = []}
      t2

  (*------------------------------------------------------------------*)
  (** Exported.
      Remark: term matching ignores [mode]. *)
  let unify =
    unif_gen
      Equiv.Local_t `Unif
      (fun[@warning "-27"] ~mode -> tunif)

  (*------------------------------------------------------------------*)
  let unify_opt 
      ?mv
      (table : Symbols.table)
      (system  : SE.context)
      (t1    : term pat)
      (t2    : term pat) 
    : Mvar.t option
    =
    match unify ?mv table system t1 t2 with
    | FreeTyv | NoMatch _ -> None
    | Match mv -> Some mv

  (*------------------------------------------------------------------*)
  (** Exported *)
  let find
      ?option
      (table  : Symbols.table) 
      (system : SE.context) 
      (pat    : term pat) 
      (t      : t) 
    : Term.term list
    =
    let f_fold : Term.terms Pos.f_map_fold = 
      fun e se _vars _conds _p acc ->
        let subterm_system = SE.reachability_context se in
        match try_match ~expand_context:InSequent 
                ?option table subterm_system e pat with
        | Match _ -> e :: acc, `Continue
        | _       -> acc, `Continue
    in
    let acc, _, _ = Pos.map_fold f_fold system.set [] t in
    acc
end

(*------------------------------------------------------------------*)
(** {3 Data-structures representing various sets of terms} *)

(*------------------------------------------------------------------*)
(** Set of terms over some index or timestamp variables with pending substitution.
    If the type variable ['a] is [Term.term list], then
      [{ term  = [t1; ...; tn];
         subst = θ;
         vars  = vars;
         cond  = φ; }]
    represents the set of tuples of terms [\{(t1, ..., tn)θ | ∀ vars s.t. φθ \}].

    The case ['a = Term.term] is identical to the case where
    ['a = Term.term list] and the list is of length 1.

    Note: [θ] supports is *not* always included in [vars]. *)
type 'a cand_set_g = {
  term  : 'a;
  subst : Mvar.t;
  vars  : Vars.vars;
  cond  : Term.term;
}
(* TODO: det: candidate sets should have tagged vars *)

type cand_set       = Term.term  cand_set_g
type cand_tuple_set = Term.terms cand_set_g

type cand_sets       = cand_set       list
type cand_tuple_sets = cand_tuple_set list

(*------------------------------------------------------------------*)
(** Set of terms over some variables of sort index or timestamp,
    under a condition.
      [{ term    = t;
         vars    = vars;
         cond    = ψ; }]
    represents the set of terms [\{t | ∀ vars, s.t. ψ \}]. *)
type known_set = {
  term : Term.term;
  vars : Vars.tagged_vars;            (* sort index or timestamp *)
  cond : Term.term;
}

(** association list sorting [known_sets] by the head of the term *)
type known_sets = (term_head * known_set list) list

(*------------------------------------------------------------------*)
module MCset : sig[@warning "-32"]
  (** Set of macros over some indices, with a conditional.
        [{ msymb   = m;
           args    = args;
           indices = vars;
           cond_le = τ₀; }]
      represents the set of terms [\{m(args)@τ | ∀τ s.t. τ ≤ τ₀ and ∀ vars \}].

      Remarks: [(fv τ₀) ∩ vars = ∅], and if [cond_le = None], then there
      is no trace model constraint. *)
  type t = private {
    msymb   : Term.msymb;
    args    : Term.term list;
    indices : Vars.var list;
    cond_le : Term.term option;
  }

  val mk :
    env:Vars.env ->
    args:Term.term list ->
    msymb:Term.msymb ->
    indices:(Vars.var list) ->
    cond_le:(Term.term option) ->
    t

  val pp       : Format.formatter -> t      -> unit
  val pp_dbg   : Format.formatter -> t      -> unit
  val pp_l     : Format.formatter -> t list -> unit
  val pp_l_dbg : Format.formatter -> t list -> unit
end = struct
  type t = {
    msymb   : Term.msymb;
    args    : Term.term list;
    indices : Vars.var list;
    cond_le : Term.term option;
  }

  let mk ~env ~args ~msymb ~indices ~cond_le : t =
    assert (
      Sv.disjoint
        (Sv.of_list1 indices)
        (Utils.omap_dflt Sv.empty Term.fv cond_le));

    let indices = Sv.diff (Sv.of_list1 indices) (Vars.to_vars_set env) in
    let indices = Sv.elements indices in
    { msymb; args; indices; cond_le; }

  let _pp ~dbg fmt (mset : t) =
    (* when [dbg] is [false], we refresh variables in [mset.indices] *)
    let mset =
      if dbg then mset
      else
        let env_vars =
          Sv.diff
            (Sv.union
               (omap_dflt Sv.empty Term.fv mset.cond_le)
               (Term.fvs mset.args))
            (Sv.of_list1 mset.indices)
        in
        let env = Vars.of_set env_vars in
        let _, indices, s = Term.add_vars_simpl_env env mset.indices in
        { msymb = mset.msymb;
          args = List.map (Term.subst s) mset.args;
          indices;
          cond_le = omap (Term.subst s) mset.cond_le; }
    in

    let pp_cond fmt = function
      | None -> Fmt.pf fmt "⊤"
      | Some cond_le ->
        Fmt.pf fmt "@[τ ≤ %a@]"
          Term.pp cond_le
    in
    match mset.indices with
    | [] ->
      Fmt.pf fmt "@[<hv 2>{ @[%a@]@τ |@ ∀ τ. %a}@]"
        Term.pp_msymb mset.msymb
        pp_cond mset.cond_le

    | _ ->
      Fmt.pf fmt "@[<hv 2>{ @[%a@]@τ |@ ∀ @[τ,%a@]. s.t. %a}@]"
        Term.pp_msymb mset.msymb
        (Fmt.list ~sep:Fmt.comma Vars.pp) mset.indices
        pp_cond mset.cond_le

  let pp_dbg = _pp ~dbg:true

  let pp = _pp ~dbg:false

  let _pp_l ~dbg fmt (mset_l : t list) =
    Fmt.pf fmt "@[<v 0>%a@]"
      (Fmt.list ~sep:Fmt.sp (_pp ~dbg)) mset_l

  let pp_l_dbg = _pp_l ~dbg:true

  let pp_l = _pp_l ~dbg:false

end

(** msets sorted in an association list *)
type msets = (Symbols.macro * MCset.t list) list

let msets_to_list (msets : msets) : MCset.t list =
  List.concat_map (fun (_, l) -> l) msets

(*------------------------------------------------------------------*)
let pp_msets fmt (msets : msets) =
  let mset_l = msets_to_list msets in
  MCset.pp_l fmt mset_l

(*------------------------------------------------------------------*)
let[@warning "-32"] pp_cand_set pp_term fmt (cand : 'a cand_set_g) =
  let pp_subst fmt mv =
    Fmt.pf fmt "[%a]" Mvar.pp mv
  in

  let vars = cand.vars in

  Fmt.pf fmt "@[<hv 2>{ @[%a@]@[%a@] |@ @[%a@]@ @[%a@]}@]"
    pp_term cand.term
    pp_subst cand.subst
    (Fmt.list ~sep:Fmt.comma Vars.pp) vars
    Term.pp cand.cond

(*------------------------------------------------------------------*)
let pp_known_set fmt (known : known_set) =
  Fmt.pf fmt "@[<hv 2>{ @[%a@] |@ %a@[%a@]}@]"
    Term.pp known.term
    Vars.pp_typed_tagged_list known.vars
    Term.pp known.cond

let pp_known_sets fmt (ks : known_sets) =
  Fmt.pf fmt "@[<v>";
  List.iter (fun (head, k_l) ->
      Fmt.pf fmt "head: %a@;@[<v>%a@]"
        pp_term_head head
        (Fmt.list ~sep:Fmt.cut pp_known_set) k_l;
      Fmt.cut fmt ();
    ) ks;
  Fmt.pf fmt "@]"

let known_sets_add (k : known_set) (ks : known_sets) : known_sets =
  List.assoc_up_dflt (get_head k.term) [] (fun ks_l -> k :: ks_l) ks

let known_sets_union (s1 : known_sets) (s2 : known_sets) : known_sets =
  let s = List.fold_left (fun s (head, k_l) ->
      let k_l' = List.assoc_dflt [] head s2 in
      (head, k_l' @ k_l) :: s
    ) [] s1
  in
  List.fold_left (fun s (head', k_l') ->
      if List.mem_assoc head' s1 then s
      else (head', k_l') :: s
    ) s s2

(*------------------------------------------------------------------*)
let known_set_of_term (term : Term.term) : known_set =
  let vars, term = match term with
    | Quant (Seq, vars, term) ->
      let vars, s = Term.refresh_vars vars in
      let term = Term.subst s term in
      vars, term

    | _ -> [], term
  in
  { term = term;
    vars = Vars.Tag.global_vars ~const:true vars;
    cond = Term.mk_true; }

(** Special treatment of `frame`, to account for the fact
    that it contains all its prefix frame and exec, and inputs.
    Remark: this is correct even if [ts] does not happens. Indeed, in that case,
    the condition [ts' ≤ ts] is never satisfied. *)
let known_set_add_frame (k : known_set) : known_set list =
  match k.term with
  | Term.Macro (ms, l, ts) when ms = Term.frame_macro ->
    assert (l = []);
    let tv' = Vars.make_fresh Type.Timestamp "t" in
    let ts' = Term.mk_var tv' in
    (* [det] is set to true, as knowing [frame@t] implies that we known
       [input@t'] for any [t' <= t], even if [t'] is non-deterministic. 
       Furthermore, this implies that we known [t]. *)
    let vars = (tv', Vars.Tag.make ~const:false Vars.Global) :: k.vars in

    let term_frame = Term.mk_macro ms [] ts' in
    let term_exec  = Term.mk_macro Term.exec_macro [] ts' in
    let term_input = Term.mk_macro Term.in_macro [] ts' in

    let mk_and = Term.mk_and ~simpl:true in

    { term = term_frame;
      vars;
      cond = mk_and (Term.mk_atom `Leq ts' ts) k.cond; } ::
    { term = term_exec;
      vars;
      cond = mk_and (Term.mk_atom `Leq ts' ts) k.cond; } ::
    [{ term = term_input;       (* input is know one step further *)
       vars;
       cond = mk_and (Term.mk_atom `Leq (Term.mk_pred ts') ts) k.cond; }]

  | _ -> []

(** Give a set of known terms [k], decompose it as a set of set of know 
    termes [k1, ..., kn] such that:
    - for all i, [ki] is deducible from [k]
    - [k] is deducible from [(k1, ..., kn)] *)
let rec known_set_decompose (k : known_set) : known_set list =
  match k.term with
  (* Exploit the pair symbol injectivity.
      If [k] is a pair, we can replace [k] by its left and right
      composants w.l.o.g. *)
  | Term.Fun (fs, _, [a;b]) when fs = Term.f_pair ->
    let kl = { k with term = a; }
    and kr = { k with term = b; } in
    List.concat_map known_set_decompose (kl :: [kr])

  (* Idem for tuples. *)
  | Term.Tuple l ->
    let kl = List.map (fun a -> { k with term = a; } ) l in
    List.concat_map known_set_decompose kl

  | _ -> [k]

(** Given a term, return some corresponding [known_sets].  *)
let known_set_list_of_term (term : Term.term) : known_set list =
  let k = known_set_of_term term in
  let k_seq = known_set_add_frame k in
  List.concat_map known_set_decompose (k :: k_seq)

let known_sets_of_terms (terms : Term.term list) : known_sets =
  let ks_l = List.concat_map known_set_list_of_term terms in
  List.fold_left (fun ks k -> known_sets_add k ks) [] ks_l

(*------------------------------------------------------------------*)
(** Assume that we know all terms in [mset]. If [extra_cond_le = Some ts'], add
    an additional constraint [t ≤ ts']. *)
let known_set_of_mset
    ?extra_cond_le
    (mset : MCset.t) : known_set
  =
  let t = Vars.make_fresh Type.Timestamp "t" in
  let term = Term.mk_macro mset.msymb mset.args (Term.mk_var t) in
  let cond =
    let cond_le = match mset.cond_le with
      | None -> Term.mk_true
      | Some cond_le ->
        Term.mk_atom `Leq (Term.mk_var t) cond_le
    in
    let extra_cond_le = match extra_cond_le with
      | None -> Term.mk_true
      | Some ts' ->
        (Term.mk_atom `Lt (Term.mk_var t) ts')
    in
    Term.mk_and ~simpl:true cond_le extra_cond_le
  in
  { term = term;
    vars = Vars.Tag.global_vars ~const:true (t :: mset.indices);
    cond; }

let known_sets_of_mset_l
    ?extra_cond_le
    (msets : MCset.t list) : known_sets
  =
  List.fold_left (fun (known_sets : known_sets) (mset : MCset.t) ->
      let new_ks = known_set_of_mset ?extra_cond_le mset in
      known_sets_add new_ks known_sets
    ) [] msets

(*------------------------------------------------------------------*)
(* return: substitution, condition, pattern *)
let pat_of_cand_set
    (cand : cand_set) : Mvar.t * Term.term * Term.term pat
  =
  cand.subst,
  cand.cond,
  { pat_term   = cand.term;
    pat_vars   = Vars.Tag.local_vars cand.vars;
    pat_tyvars = []; }

(* return: condition, pattern *)
let pat_of_known_set (known : known_set) : Term.term * Term.term pat =
  known.cond,
  { pat_term   = known.term;
    pat_vars   = known.vars;
    pat_tyvars = []; }

(*------------------------------------------------------------------*)
let refresh_known_set (known : known_set) : known_set =
  let vars, subst = Term.refresh_vars_w_info known.vars in
  { vars;
    term = Term.subst subst known.term;
    cond = Term.subst subst known.cond; }

(*------------------------------------------------------------------*)
let msets_add (mset : MCset.t) (msets : msets) : msets =
  let name = mset.msymb.s_symb in
  if List.mem_assoc name msets then
    List.assoc_up name (fun b -> mset :: b) msets
  else (name, [mset]) :: msets

(** [mset_incl tbl system s1 s2] check if all terms in [s1] are
    members of [s2]. *)
let mset_incl 
    (table : Symbols.table) (system : SE.arbitrary) 
    (s1 : MCset.t) (s2 : MCset.t) : bool
  =
  let tv = Vars.make_fresh Type.Timestamp "t" in
  let term1 = Term.mk_macro s1.msymb s1.args (Term.mk_var tv) in
  let term2 = Term.mk_macro s2.msymb s2.args (Term.mk_var tv) in

  assert (s1.cond_le = s2.cond_le);

  let pat2 = {
    pat_term = term2;
    pat_tyvars = [];
    pat_vars = Vars.Tag.local_vars s2.indices;
    (* local inforation, since we allow to match diff operators *)
  } in

  let context = SE.{ set = system; pair = None; } in
  (* FIXME: cleanup with unification of list of terms *)
  (* FIXME: use better expand_context mode when possible *)
  match 
    T.try_match ~expand_context:InSequent table context term1 pat2
  with
  | FreeTyv | NoMatch _ -> false
  | Match _ -> true


(** [msets_incl tbl system s1 s2] check if [msets] is included in [msets2] *)
let msets_incl 
    (table : Symbols.table) (system : SE.arbitrary)
    (msets1 : msets) (msets2 : msets) : bool 
  =
  List.for_all (fun (mname, mset1_l) ->
      let mset2_l = List.assoc_opt mname msets2 in
      let mset2_l = odflt [] mset2_l in

      List.for_all (fun mset1 ->
          List.exists (fun mset2 ->
              mset_incl table system mset1 mset2
            ) mset2_l
        ) mset1_l
    ) msets1


(** remove any set which is subsumed by some other set. *)
let mset_list_simplify 
    (table : Symbols.table) (system : SE.arbitrary)
    (msets : MCset.t list) : MCset.t list 
  =
  let rec clear_entailed before after =
    match after with
    | [] -> List.rev before
    | mset :: after ->
      let clear =
        List.exists (fun mset' ->
            mset_incl table system mset mset'
          ) (before @ after)
      in
      if clear then
        clear_entailed before after
      else
        clear_entailed (mset :: before) after
  in
  clear_entailed [] msets

let mset_refresh env (mset : MCset.t) : MCset.t =
  let indices, subst = Term.refresh_vars mset.indices in

  let args = List.map (Term.subst subst) mset.args in
  let cond_le = omap (Term.subst subst) mset.cond_le in
  MCset.mk ~env ~msymb:mset.msymb ~args ~indices ~cond_le

(** applies a substitution `θ` to a mset, where `θ` can bind
    index variables which used to be universally quantified. *)
let mset_subst env subst (mset : MCset.t) : MCset.t =
  let args = List.map (Term.subst subst) mset.args in
  let indices = List.map (Term.subst_var subst) mset.indices in
  let cond_le = omap (Term.subst subst) mset.cond_le in
  MCset.mk ~env ~msymb:mset.msymb ~args ~indices ~cond_le

(** Compute the intersection of two msets with the same condition. Exact. *)
let mset_inter
    table system (env : Vars.env)
    (s1 : MCset.t) (s2 : MCset.t)
  : MCset.t option
  =
  let s1, s2 = mset_refresh env s1, mset_refresh env s2 in

  let tv = Vars.make_fresh Type.Timestamp "t" in
  let term1 = Term.mk_macro s1.msymb s1.args (Term.mk_var tv) in
  let term2 = Term.mk_macro s2.msymb s2.args (Term.mk_var tv) in

  let pat1 = {
    pat_term   = term1;
    pat_tyvars = [];
    pat_vars   = Vars.Tag.local_vars s1.indices;}
  (* local inforation, since we allow to match diff operators *)
  in
  let pat2 = {
    pat_term   = term2;
    pat_tyvars = [];
    pat_vars   = Vars.Tag.local_vars s2.indices;}
  (* local inforation, since we allow to match diff operators *)
  in
  (* FIXME: cleanup with unification of list of terms *)
  let sys_cntxt = SE.{ set = system; pair = None; } in
  match T.unify_opt table sys_cntxt pat1 pat2 with
  | None -> None
  | Some mv ->

    assert (s1.cond_le = s2.cond_le);

    let subst = Mvar.to_subst_locals ~mode:`Unif mv in
    let mset = mset_subst env subst s1 in
    assert (
      let mset' = mset_subst env subst s2 in
      mset = mset');
    Some mset


(** Intersets two list of [mset]s by doing:
    (∪ᵢ sᵢ) ∩ (∪ᵢ sᵢ) = ∪ᵢ,ⱼ (sᵢ∩sⱼ) *)
let mset_list_inter
    (table   : Symbols.table)
    (system  : SE.t)
    (env     : Vars.env)
    (mset_l1 : MCset.t list)
    (mset_l2 : MCset.t list) : MCset.t list
  =
  let mset_l =
    List.fold_left (fun acc mset1 ->
        List.fold_left (fun acc mset2 ->
            match mset_inter table system env mset1 mset2 with
            | None -> acc
            | Some s -> s :: acc
          ) acc mset_l1
      ) [] mset_l2
  in
  mset_list_simplify table system mset_l

(*------------------------------------------------------------------*)
(** [{term; cond;}] is the term [term] whenever [cond] holds. *)
type cond_term = { term : Term.term; cond : Term.term }


(*------------------------------------------------------------------*)
(** {3 Equiv matching and unification} *)


module E : S with type t = Equiv.form = struct
  (* We include Term.Match, and redefine any necessary function *)
  include T

  type t = Equiv.form

  (*------------------------------------------------------------------*)
  let leq_tauto table (t : Term.term) (t' : Term.term) : bool =
    let rec leq t t' =
      match t,t' with
      | _ when t = t' -> true
      | Fun (f,_, [t]), Fun (f',_, [t']) 
        when f = f_pred && f' = f_pred ->
        leq t t'
      | Fun (f,_, [t]), t' when f = f_pred -> leq t t'

      | Action (n,is), Action (n',is') ->
        Action.depends
          (Action.of_term n is table)
          (Action.of_term n' is' table)

      | _ -> false
    in
    leq t t'

  (** Check that [hyp] implies [cond].
      We only support a restricted set of possible known sets conditions
      for now. *)
  let known_set_check_impl
      (table : Symbols.table)
      (hyp   : Term.term)
      (cond  : Term.term) : bool
    =
    let hyps = Term.decompose_ands hyp in

    let check_one cond =
      match cond with
      | Term.Fun (fs, _, [t1;t2]) 
        when (fs = Term.f_lt || fs = Term.f_leq)
          && Term.ty t1 = Type.Timestamp ->
        let t2' =
          if fs = Term.f_lt then Term.mk_pred t2 else t2
        in

        let check_direct = leq_tauto table t1 t2' in
        let check_indirect =
          List.exists (fun hyp ->
              match hyp with
              | Term.Fun (fs, _, [ta;tb]) 
                when fs = Term.f_leq && Term.ty t1 = Type.Timestamp -> (* ≤ *)

                (* checks whether [ta ≤ tb] implies [t1 ≤ t2'] *)
                leq_tauto table t1 ta && leq_tauto table tb t2'

              | Term.Fun (fs,_,_) when fs = Term.f_true -> false

              | _ -> false
            ) hyps
        in
        check_direct || check_indirect

      | Term.Fun (fs,_,_) when fs = Term.f_true -> true

      | _ -> assert false
    in
    List.for_all check_one (Term.decompose_ands cond)

  
  (** Return a specialization of [cand] that is a subset of [known]. *)
  let specialize
      (table  : Symbols.table)
      (system : SE.fset)
      (cand   : cand_set)
      (known  : known_set) : cand_set option
    =
    let known = refresh_known_set known in

    let mv, c_cond, c_pat = pat_of_cand_set cand in
    let known_cond, e_pat = 
      pat_of_known_set
        { known with vars = Vars.Tag.local_vars (List.map fst known.vars) } 
        (* TODO: det: do not erase tags info *)
    in

    let sys_cntxt = SE.{ set = (system :> SE.t); pair = None; } in
    match T.unify_opt ~mv table sys_cntxt c_pat e_pat with
    | None -> None
    | Some mv -> (* [mv] represents substitution [θ] *)
      let subst = Mvar.to_subst_locals ~mode:`Unif mv in

      (* check that [c_cond θ] implies [known_cond θ] holds *)
      let known_cond = Term.subst subst known_cond
      and c_cond     = Term.subst subst c_cond in

      if not (known_set_check_impl table c_cond known_cond) then None
      else
        let cand =
          { term = cand.term;
            subst = mv;
            (* Note: variables must *not* be cleared yet,
               because we must not forget the instantiation by [mv] of any
               variable. *)
            vars = cand.vars @ List.map fst known.vars;
            (* TODO: det: do not erase tag info *)
            cond = cand.cond; }
        in
        Some cand


  (* profiling *)
  let specialize = Prof.mk_ternary "specialize" specialize

  (*------------------------------------------------------------------*)
  let specialize_all
      (table  : Symbols.table)
      (system : SE.fset)
      (cand   : cand_set)
      (known_sets : known_sets) : cand_sets
    =
    let cand_head = get_head cand.term in
    let cands =
      List.fold_left (fun acc (head, known_list) ->
          if cand_head = HVar || head = HVar || cand_head = head then
            List.fold_left (fun acc known ->
                specialize table system cand known :: acc
              ) acc known_list
          else acc
        ) [] known_sets
    in
    List.concat_map (function
        | None -> []
        | Some x -> [x]
      ) cands

  (*------------------------------------------------------------------*)
  (** Return a list of specialization of [cand] deducible from [terms] and
      [known].
      This includes both direct specialization, and specialization relying on
      the Function Application rule. *)
  let rec deduce
      (table  : Symbols.table)
      (env    : Vars.env)
      (system : SE.fset)
      (cand   : cand_set)
      (known_sets : known_sets) : cand_sets
    =
    let direct_deds = specialize_all table system cand known_sets in
    let fa_deds = deduce_fa table env system cand known_sets in

    direct_deds @ fa_deds

  (** Return a list of specialization of the tuples in [cand] deducible from
      [terms] and [pseqs]. *)
  and deduce_list
      (table  : Symbols.table)
      (env    : Vars.env)
      (system : SE.fset)
      (cand : cand_tuple_set)
      (known_sets : known_sets) : cand_tuple_sets
    =
    match cand.term with
    | [] -> [cand]
    | t :: tail ->
      (* find deducible specialization of the first term of the tuple. *)
      let t_deds = deduce table env system { cand with term = t } known_sets in

      (* for each such specialization, complete it into a specialization of
         the full tuple. *)
      List.concat_map (fun t_ded ->
          (* find a deducible specialization of the tail of the tuple,
             starting from the  specialization of [t]. *)
          let cand_tail : cand_tuple_set = { t_ded with term = tail } in
          let tail_deds = deduce_list table env system cand_tail known_sets in

          (* build the deducible specialization of the full tuple. *)
          List.map (fun (tail_ded : cand_tuple_set) ->
              { tail_ded with term = t_ded.term :: tail_ded.term }
            ) tail_deds
        ) t_deds

  (** Return a list of specialization of [cand] deducible from [terms] and
      [pseqs] using Function Application.
      Does not include direct specialization. *)
  and deduce_fa
      (table  : Symbols.table)
      (env    : Vars.env)
      (system : SE.fset)
      (cand   : cand_set)
      (known_sets : known_sets) : cand_sets
    =
    (* [mk_cand_of_terms] build back the know terms from the known 
       sub-terms. *)
    let comp_deds
        (mk_cand_of_terms : terms -> term) (terms : Term.terms) 
      : cand_sets 
      =
      let terms_cand = { cand with term = terms } in
      let terms_deds = deduce_list table env system terms_cand known_sets in
      List.map (fun (terms_ded : cand_tuple_set) ->
          { terms_ded with
            term = mk_cand_of_terms terms_ded.term }
        ) terms_deds
    in

    let cand_env =
      let vars = Vars.add_vars (Vars.Tag.global_vars ~const:true cand.vars) env in
      Env.init ~table ~system:{ set = (system :> SE.arbitrary); pair = None; } ~vars ()
    in

    (* decompose the term using Function Application,
       find a deducible specialization of its tuple of arguments,
       and build the deducible specialization of the initial term. *)
    match cand.term with
    (* special case for pure timestamps *)
    | _ as f when HighTerm.is_ptime_deducible ~const:`Exact ~si:true cand_env f -> [cand]

    | Term.Macro (ms, l, ts) ->
      begin
        let cntxt = Constr.make_context ~system ~table in
        match Macros.get_definition cntxt ms ~args:l ~ts with
        | `Undef | `MaybeDef -> []
        | `Def body ->
          deduce table env system { cand with term = body } known_sets
      end

    | Term.Proj (i,t) -> 
      comp_deds (fun t -> Term.mk_proj i (as_seq1 t)) [t]

    | Term.Tuple f_terms -> 
      comp_deds (fun f_terms -> Term.mk_tuple f_terms) f_terms

    | Term.Fun (fs, fty, f_terms) ->
      comp_deds (fun f_terms -> Term.mk_fun0 fs fty f_terms) f_terms

    | Term.App (t, l) -> 
      comp_deds (fun t_l ->
          let t, l = List.takedrop 1 t_l in
          let t = as_seq1 t in
          Term.mk_app t l
        ) (t :: l)

    | _ -> []

  (*------------------------------------------------------------------*)
  (** [strenghten tbl system terms] strenghten [terms] by finding an inductive
      invariant on deducible messages which contains [terms]. *)
  let strengthen
      (table  : Symbols.table)
      (system : SE.fset)
      (env    : Vars.env)
      (init_terms : Term.terms) : msets
    =
    (* Return a list of specialization of [cand] deducible from
       [init_terms, known_sets] for action [a] at time [a]. *)
    let filter_deduce_action
        (a : Symbols.action)
        (cand : MCset.t)
        (init_terms : known_sets)              (* initial terms *)
        (known_sets : MCset.t list)            (* induction *)
      : MCset.t list
      =
      (* we create the timestamp at which we are *)
      let i = Action.arity a table in
      let is = 
        List.init i (fun _ -> Vars.make_fresh Type.Index "i")
      in
      let ts = Term.mk_action a (List.map Term.mk_var is) in

      (* we unroll the definition of [cand] at time [ts] *)
      let cntxt = Constr.make_context ~system ~table in
      match Macros.get_definition cntxt cand.msymb ~args:cand.args ~ts with
      | `Undef | `MaybeDef -> []

      | `Def body ->
        let cond = match cand.cond_le with
          | Some cond_le ->
            Term.mk_atom `Leq ts cond_le
          | None -> Term.mk_true
        in

        let cand_set = {
          term  = body;
          vars  = cand.indices @ is;
          subst = Mvar.empty;
          cond; }
        in
        (* we instantiate the known terms at time [ts] *)
        let all_known_sets =
          (* we assume we know all terms in [known_sets] at time [ts] *)
          let known_sets = known_sets_of_mset_l ~extra_cond_le:ts known_sets in
          known_sets_union init_terms known_sets
        in
        let ded_sets = deduce table env system cand_set all_known_sets in

        let mset_l =
          List.fold_left (fun mset_l ded_set ->
              let subst = Mvar.to_subst_locals ~mode:`Unif ded_set.subst in
              let msymb = cand.msymb in
              let args  = List.map (Term.subst subst) cand.args in
              let indices = List.map (Term.subst_var subst) cand.indices in
              let mset = 
                MCset.mk ~env ~msymb ~args ~indices ~cond_le:cand.cond_le 
              in

              (* sanity check *)
              let () =
                assert (match ded_set.cond with
                    | Term.Fun (fs, _, [_; c]) when fs = Term.f_leq ->
                      Some c = cand.cond_le
                    | Term.Fun (_fs,_,_) -> None = cand.cond_le
                    | _ -> false)
              in

              mset :: mset_l
            ) [] ded_sets
        in
        mset_list_simplify table (system:>SE.t) mset_l
    in

    let filter_deduce_action_list
        (a : Symbols.action)
        (cands : msets)
        (init_terms : known_sets)              (* initial terms *)
        (known_sets : MCset.t list)            (* induction *)
      : msets
      =
      List.map (fun (mname, cand_l) ->
          let mset_l =
            List.concat_map (fun cand ->
                filter_deduce_action a cand init_terms known_sets
              ) cand_l
          in
          (mname, mset_list_inter table (system:>SE.t) env cand_l mset_l)
        ) cands
    in

    (* fold over all actions of the protocol, to find a specialization of
       [cands] stable by each action. *)
    let filter_deduce_all_actions
        (cands : msets)
        (init_terms : known_sets)              (* initial terms *)
        (known_sets : MCset.t list)            (* induction *)
      : msets
      =
      let names = SE.symbs table system in
      System.Msh.fold (fun _ name cands ->
          filter_deduce_action_list name cands init_terms known_sets
        ) names cands
    in

    let rec deduce_fixpoint
        (cands : msets)
        (init_terms : known_sets) (* initial terms *)
      : msets
      =
      let init_known : MCset.t list = msets_to_list cands in
      let cands' = filter_deduce_all_actions cands init_terms init_known in

      dbg "deduce_fixpoint:@.%a@." pp_msets cands';

      (* check if [cands] is included in [cands'] *)
      if msets_incl table (system:>SE.t) cands cands'
      then cands'
      else deduce_fixpoint cands' init_terms
    in

    (* we use as maximal timestamp the first timestamp appearing in a
       frame. If there is no such timestamp, we have no constraints. *)
    let cond_le =
      List.find_map (function
          | Term.Macro (ms, _, ts) when ms = Term.frame_macro -> Some ts
          | _ -> None
        ) init_terms
    in

    let init_fixpoint : msets =
      Symbols.Macro.fold (fun mn def _ msets ->
          match def with
          | Symbols.Global _
          | Symbols.Input | Symbols.Output | Symbols.Frame | Symbols.Exec -> msets

          (* ignore global macros, as they are (usually) not defined at
             all timestamps, so we won't find a deduction invariant with
             them. *)
          | _ ->
            let ty, indices = match def with
              | Symbols.Input | Symbols.Output | Symbols.Frame | Symbols.Exec
              | Symbols.Global _ -> assert false

              | Symbols.State (i, ty) ->
                ty, List.init i (fun _ -> Vars.make_fresh Type.Index "i")

              | Symbols.Cond ->
                Type.Boolean, []
            in
            let ms = Term.mk_symb mn ty in
            let mset = 
              MCset.mk ~env
                ~msymb:ms ~args:(Term.mk_vars indices) ~indices ~cond_le 
            in
            msets_add mset msets
        ) [] table
    in
    dbg "init_fixpoint:@.%a@." pp_msets init_fixpoint;

    (* initially known terms *)
    let init_terms = known_sets_of_terms init_terms in

    dbg "init_terms:@.%a@." pp_known_sets init_terms;

    deduce_fixpoint init_fixpoint init_terms

  (* memoisation *)
  let strengthen =
    let module M = struct
      type t = Symbols.table * SE.fset * Vars.env * Term.terms

      let hash (tbl, s, e, terms) =
        hcombine_list Term.hash
          (hcombine (Symbols.tag tbl)
             (hcombine (SE.hash s)
                (Hashtbl.hash e))) (* FIXME: better hash? *)
          terms

      let equal (tbl, s, e, terms) (tbl', s', e', terms') =
        Symbols.tag tbl = Symbols.tag tbl' &&
        s = s' &&
        e = e' &&               (* FIXME: better eq check? *)
        List.length terms = List.length terms' &&
        List.for_all2 (=) terms terms' (* FIXME: term hashconsing *)

    end in
    (* FIXME: memory leaks *)
    let module Memo = Hashtbl.Make(M) in
    let memo = Memo.create 256 in
    fun tbl s e terms ->
      try Memo.find memo (tbl, s, e, terms) with
      | Not_found ->
        let r = strengthen tbl s e terms in
        Memo.add memo (tbl, s, e, terms) r;
        r

  (*------------------------------------------------------------------*)
  let flip = function
    | `Eq        -> `Eq
    | `Covar     -> `Contravar
    | `Contravar -> `Covar

  (*------------------------------------------------------------------*)
  (** [term_match ?vars term pat st] match [term] with [pat] w.r.t.
      variables [vars]. *)
  let term_unif term pat st : Mvar.t =
    try T.tunif term pat st with
    | NoMatch _ -> no_unif ()  (* FIXME: why throw away match info? *)

  (*------------------------------------------------------------------*)
  (** Try to match [cterm] as an element of [known]. *)
  let _deduce_mem_one
      (cterm : cond_term)
      (known : known_set)
      (st    : unif_state) : Mvar.t option
    =
    let known = refresh_known_set known in

    let known_cond, e_pat = pat_of_known_set known in

    assert (
      Sv.disjoint
        (Sv.of_list (List.map fst known.vars))
        (Sv.of_list (List.map fst st.support))
    );
    (* Elements of [known] are known only for bi-deducible values of [known.vars]. 
       For now, we only check that these [known.vars] is instantiated by 
       deterministic (* TODO: ptime *) values, which ensures that they are bi-deducible.
       FEATURE: we could be more precise by creating a bi-deduciton proof obligation instead. *)
    let st = { st with support = known.vars @ st.support; } in

    (* adding [cterm.cond] as hypohtesis before matching *)
    let st =
      let hyps =
        Lazy.map
          (TraceHyps.add TacticsArgs.AnyName (Equiv.Local cterm.cond))
          st.hyps
      in
      { st with hyps }
    in

    try
      let mv = T.tunif cterm.term e_pat.pat_term st in

      let subst =
        match Mvar.to_subst ~mode:`Unif st.table st.env mv with
        | `Subst subst -> subst
        | `BadInst _pp_err ->
          (* Fmt.epr "bad instanciation: %t@." _pp_err; *) 
          no_unif ()
      in
      let known_cond = Term.subst subst known_cond in

      (* check that [cterm.cond] imples [known_cond θ] holds *)
      if not (known_set_check_impl st.table cterm.cond known_cond) then None
      else                      (* clear [known.var] from the binding *)
        Some (Mvar.filter (fun v _ -> not (List.mem_assoc v known.vars)) mv)
    with NoMatch _ -> None

  let deduce_mem_one
      (cterm : cond_term)
      (known : known_set)
      (st    : unif_state) : Mvar.t option
    =
    (* FIXME:
       if [st.support] is not empty, then we need to find [mv] such that:
       - [mv] represents a substitution θ whose support is included in
         [st.support] ∪ [known.vars]
       - for any v ∈ [st.support], (fv(θ(v)) ∩ st.bvs = ∅)

       The issue is that the matching algorithm will ensure that the latter
       condition holds for ([st.support] ∪ [known.vars]), and not just
       for [st.support]. This makes us reject valid instance that appear in
       practice.

       We need to modify the matching algorithm to account for that.

       Instead, for now, we try either a normal matching, or a matching where we
       cleared both [st.bvs] and [st.support] (i.e. we do not try to infer the
       arguments of the lemma being applied).
       We move [st.bvs] to [st.env] to keep variable tags information.
    *)
    match _deduce_mem_one cterm known st with
    | Some mv -> Some mv
    | None -> (* try again, with empty [support] and [bvs], moving [bvs] to [env] *)
      let env = Vars.add_vars st.bvs st.env in
      let st = { st with bvs = []; support = []; env; } in
      _deduce_mem_one cterm known st


  (** Try to match [term] as an element of a sequence in [elems]. *)
  let deduce_mem
      (cterm : cond_term)
      (elems : known_sets)
      (st    : unif_state) : Mvar.t option
    =
    let elems_head = List.assoc_dflt [] (get_head cterm.term) elems in
    List.find_map (fun elem -> deduce_mem_one cterm elem st) elems_head
 
  (*------------------------------------------------------------------*)
  (** [fa_decompose term st] return a list of matching conditions that must be
      met for [term] to be deducible starting from [st].
      Return [None] if Function Application fails on [term] *)
  let fa_decompose
      (cterm : cond_term)
      (st    : unif_state) : (unif_state * cond_term) list option
    =
    let env = env_of_unif_state st in  

    match cterm.term with
    | t when HighTerm.is_ptime_deducible ~const:`Exact ~si:true env t -> Some []
  
    (* function: if-then-else *)
    | Term.Fun (f, _, [b; t1; t2] ) when f = Term.f_ite ->
      let cond1 = Term.mk_and b cterm.cond
      and cond2 = Term.mk_and (Term.mk_not b) cterm.cond in

      Some (List.map (fun t -> st, t) [{ term = b ; cond = cterm.cond; };
                                       { term = t1; cond = cond1; };
                                       { term = t2; cond = cond2; }])

    (* function: general case + tuples *)
    | Term.Tuple terms
    | Term.Fun (_, _, terms) -> 
      Some (List.map (fun term -> st, { cterm with term } ) terms)

    | Term.Proj (_, t) ->
      Some [st, { cterm with term = t }]

    | Term.App (t, terms) ->
      Some (List.map (fun term -> st, { cterm with term } ) (t :: terms))

    | Term.Quant (q, es, term) ->
      (* [ForAll] and [Exists] require quant. over finite fix types *)
      let check_quantif =
        match q with
        | Seq | Lambda -> true
        | ForAll | Exists -> 
          List.for_all (fun v -> 
              Symbols.TyInfo.is_finite st.table (Vars.ty v) && 
              Symbols.TyInfo.is_fixed  st.table (Vars.ty v)) es 
      in
      if not check_quantif then 
        None 
      else
        let es, subst = Term.refresh_vars es in
        let term = Term.subst subst term in

        (* binder variables are declared global and deterministic,
           as these are inputs (hence known values) to the adversary  *)
        let st = { st with bvs = (Vars.Tag.global_vars ~const:true es) @ st.bvs; } in
        Some [(st, { cterm with term; })]

    | Find (is, c, d, e)
      when List.for_all
          (fun v -> 
             Symbols.TyInfo.is_finite st.table (Vars.ty v) && 
             Symbols.TyInfo.is_fixed  st.table (Vars.ty v)
          ) is 
      ->
      let is, subst = Term.refresh_vars is in
      let c, d = Term.subst subst c, Term.subst subst d in

      (* idem, binder variables are declared global and deterministic *)
      let st1 = { st with bvs = (Vars.Tag.global_vars ~const:true is) @ st.bvs; } in

      let d_cond = Term.mk_and cterm.cond c in
      let e_cond =
        Term.mk_and
          cterm.cond
          (Term.mk_forall is (Term.mk_not c))
      in

      let c = { term = c; cond = cterm.cond; }
      and d = { term = d; cond = d_cond; }
      and e = { term = e; cond = e_cond; } in


      Some [(st1, c); (st1, d); (st, e)]

    | _ -> None

  (*------------------------------------------------------------------*)
  (** Check that [cterm] can be deduced from [pat_terms].
      This check is modulo:
      - Restr: all elements may not be used;
      - Sequence expantion: sequences may be expanded;
      - Function Application: [cterm] may be decomposed into smaller terms. *)
  let rec match_term_incl
      (cterm     : cond_term)
      (pat_terms : known_sets)
      (st        : unif_state)
      (minfos    : match_infos) : Mvar.t * match_infos
    =
    match deduce_mem cterm pat_terms st with
    | Some mv -> mv, minfos_ok cterm.term minfos
    | None ->
      (* if that fails, decompose [term] through the Function Application
         rule, and recurse. *)
      fa_match_term_incl cterm pat_terms st minfos

  (** Check that [cterm] can be deduced from [pat_terms]. *)
  and fa_match_term_incl
      (cterm     : cond_term)
      (pat_terms : known_sets)
      (st        : unif_state)
      (minfos    : match_infos) : Mvar.t * match_infos
    =
    match fa_decompose cterm st with
    | None -> st.mv, minfos_failed cterm.term minfos

    | Some fa_conds ->
      let minfos =
        let st = List.map (fun x -> (snd x).term) fa_conds in
        minfos_check_st cterm.term st minfos
      in

      List.fold_left (fun (mv, minfos) (st, t) ->
          let mv, minfos =
            match_term_incl t pat_terms { st with mv } minfos
          in
          mv, minfos
        ) (st.mv, minfos) fa_conds

  (*------------------------------------------------------------------*)
  (** Greedily check entailment through an inclusion check of [terms] in
      [pat_terms]. *)
  let match_equiv_incl
      (terms     : Term.term list)
      (pat_terms : Term.term list)
      (st        : unif_state) : Mvar.t
    =
    (* If [st.support] is not empty, we cannot strengthen the invariant.
       See explanation in [mset_mem_one]. *)
    let mset_l =
      if st.support = [] && st.use_fadup then
        let system = SE.to_fset (oget st.system.pair) in
        let msets = strengthen st.table system st.env pat_terms in
        msets_to_list msets
      else []
    in

    if st.support = [] && st.use_fadup &&
       TConfig.show_strengthened_hyp st.table then
      (dbg ~force:true) "@[<v 2>strengthened hypothesis:@;%a@;@]" MCset.pp_l mset_l;

    let pat_terms =
      known_sets_union
        (known_sets_of_mset_l mset_l)
        (known_sets_of_terms pat_terms)
    in

    let mv, minfos =
      List.fold_left (fun (mv, minfos) term ->
          let cterm = { term; cond = Term.mk_true; } in
          match_term_incl cterm pat_terms { st with mv } minfos
        ) (st.mv, Mt.empty) terms
    in

    if Mt.for_all (fun _ r -> r <> MR_failed) minfos
    then mv
    else no_unif ~infos:(terms, minfos_norm minfos) ()


  (*------------------------------------------------------------------*)
  let unif_equiv_eq
      (terms     : Term.term list)
      (pat_terms : Term.term list)
      (st        : unif_state) : Mvar.t
    =
    if List.length terms <> List.length pat_terms then no_unif ();

    List.fold_right2 (fun t1 t2 mv ->
        term_unif t1 t2 { st with mv }
      ) terms pat_terms st.mv

  (*------------------------------------------------------------------*)
  (** Check entailment between two equivalences (only in matching mode).
      - [Covar]    : [pat_es] entails [es]
      - [Contravar]: [es] entails [pat_es] *)
  let tunif_e
      ~(mode     : [`Eq | `Covar | `Contravar])
      (terms     : Term.terms)
      (pat_terms : Term.terms)
      (st        : unif_state) : Mvar.t
    =
    match mode with
    | `Eq        -> unif_equiv_eq terms pat_terms st
    | `Contravar -> unif_equiv_eq terms pat_terms st
    (* FIXME: in contravariant position, we cannot check for inclusion
       because, in the seq case, this requires to infer the seq
       variables for the *term* being matched. Consequently, this is no longer
       a matching problem, but is a unification problem. *)

    | `Covar     -> match_equiv_incl terms pat_terms st

  (*------------------------------------------------------------------*)
  (** Match two [Equiv.form] *)
  let rec e_unif ~mode (t : Equiv.form) (pat : Equiv.form) (st : unif_state)
    : Mvar.t =
    match t, pat with
    | Impl (t1, t2), Impl (pat1, pat2) ->
      let mv = e_unif ~mode:(flip mode) t1 pat1 st in
      e_unif ~mode t2 pat2 { st with mv }

    | Atom (Reach t), Atom (Reach pat) ->
      term_unif t pat st

    | Atom (Equiv es), Atom (Equiv pat_es) ->
      tunif_e ~mode es pat_es st

    | Quant (q,es,t), Quant (q',es',t') when q = q' ->
      let s, s', st = unif_tagged_bnds es es' st in
      let t  = Equiv.subst s  t  in
      let t' = Equiv.subst s' t' in
      e_unif ~mode t t' st

    | _ -> no_unif ()

  (*------------------------------------------------------------------*)
  (** Exported. *)
  let try_match
      ?option ?mv ?env ?ty_env ?hyps ?expand_context
      (table   : Symbols.table)
      (system  : SE.context)
      (t1      : Equiv.form)
      (t2      : Equiv.form pat) 
    =
    unif_gen
       Equiv.Global_t `Match
       e_unif

      (* repeat arguments, wrapping [t1] in a pattern *)
      ?option ?mv ?env ?ty_env ?hyps ?expand_context table system
      Term.{ pat_term = t1; pat_vars = []; pat_tyvars = []}
      t2
  
  (*------------------------------------------------------------------*)
  (** Exported *)
  let find
      ?option
      (table  : Symbols.table) 
      (system : SE.context) 
      (pat    : term pat) 
      (t      : Equiv.form) 
    : Term.terms
    =
    let f_fold : Term.terms Pos.f_map_fold = 
      fun e se _vars _conds _p acc ->
        let subterm_system = SE.reachability_context se in
        match 
          T.try_match ~expand_context:InSequent
            ?option table subterm_system e pat 
        with
        | Match _ -> e :: acc, `Continue
        | _       ->      acc, `Continue
    in
    let acc, _, _ = Pos.map_fold_e f_fold system [] t in
    acc
end
