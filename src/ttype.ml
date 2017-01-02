(* level inference & program transformer *)

open Error
open PiSyntax
open Location
open Type
open Sbst
open SeqSyntax

(*
 * Make constraints among levels
 *)

(* infer_proc : Type.level -> PiSyntax.pl -> ConstraintsL.t *)
let rec infer_proc env level pl =
  match pl.loc_val with
  | PNil ->
     ConstraintsL.empty
  | PIn(body) ->
     begin
       try
	 let tyx = Env.find body.x env in
	 match tyx with
	 | TChan(_, tys, _) ->
	    let env = Env.add_list body.ys tys env in
	    infer_proc env level body.pl
	 | _ ->
	    raise @@ ConvErr("infer_proc: Non-channel name on input")
       with
       | Not_found ->
	  raise @@ ConvErr("infer_proc: A variable is not found in environment")
     end
  | PRIn(body) ->
     (* Update level *)
     begin
       try
	 let tyx = Env.find body.x env in
	 match tyx with
	 | TChan(Some(l), tys, ro) ->
	    let env = Env.add_list body.ys tys env in
	    infer_proc env l body.pl
	 | TChan(None, tys, ro) ->
	    raise @@ ConvErr("infer_proc: No level information")
	 | _ ->
	    raise @@ ConvErr("infer_proc: Non-channel name on output")
       with
       | Not_found ->
	  raise @@ ConvErr("infer_proc: A variable is not found in environment")
     end
  | POut(body) ->
     (* Add a constraint *)
     begin
       try
	 let tyx = Env.find body.x env in
	 match tyx with
	 | TChan(Some(l), tys, ro) ->
	    let c = infer_proc env level body.pl in
	    ConstraintsL.add (l, level) c
	 | TChan(None, tys, ro) ->
	    raise @@ ConvErr("infer_proc: No level information")
	 | _ ->
	    raise @@ ConvErr("infer_proc: Non-channel name on output")
       with
       | Not_found ->
	  raise @@ ConvErr("infer_proc: A variable is not found in environment")
     end
  | PPar(body) ->
     let c1 = infer_proc env level body.pl1 in
     let c2 = infer_proc env level body.pl2 in
     ConstraintsL.union c1 c2
  | PRes(body) ->
     begin
       match body.tyxo with
       | Some(TChan(None, tys, ro) as tyx) ->
	  let tyx = set_level tyx in
	  body.tyxo <- Some(tyx);
	  infer_proc (Env.add body.x tyx env) level body.pl
       | Some(tyx) ->
	  infer_proc (Env.add body.x tyx env) level body.pl
       | None ->
	  raise @@ ConvErr("infer_proc: No type information")
     end
  | PIf(body) ->
     let c1 = infer_proc env level body.pl1 in
     let c2 = infer_proc env level body.pl2 in
     ConstraintsL.union c1 c2
and set_level ty =
  match ty with
  | TChan(None, tys, ro) ->
     let l = LVar(gensym_level ()) in
     TChan(Some(l), List.map set_level tys, ro)
  | _ -> ty

(*
 * type annotation
 *)

let max_level = ref Type.min_level

(* annotate_level : Type.t sbst -> PiSyntax.pl -> unit *)
let rec annotate_level sbst pl =
  match pl.loc_val with
  | PNil -> ()
  | PIn(body)
  | PRIn(body) ->
     body.tyxo <- get_type sbst body.tyxo;
     body.tyyos <- List.map (get_type sbst) body.tyyos;
     annotate_level sbst body.pl
  | POut(body) ->
     body.tyxo <- get_type sbst body.tyxo;
     annotate_level sbst body.pl
  | PPar(body) ->
     annotate_level sbst body.pl1;
     annotate_level sbst body.pl2
  | PRes(body) ->
     body.tyxo <- get_type sbst body.tyxo;
     annotate_level sbst body.pl
  | PIf(body) ->
     annotate_level sbst body.pl1;
     annotate_level sbst body.pl2
and get_type sbst tyo =
  match tyo with
  | Some(ty) -> Some(get_type' sbst ty)
  | None -> None
and get_type' sbst ty =
  match ty with
  | TChan(Some(LVar(x)), tys, ro) ->
     begin
       try
	 let l = List.assoc x sbst in
	 let tys = List.map (get_type' sbst) tys in
	 (match l with
	  | LInt(i) ->
	     if i > !max_level then max_level := i
	  | _ ->
	     raise @@ ConvErr("get_type': Not TInt"));
	 TChan(Some(l), tys, ro)
       with
       | Not_found ->
	  (* TODO(nekketsuuu): これでいいか確認 *)
	  let tys = List.map (get_type' sbst) tys in
	  TChan(Some(LInt(Type.min_level)), tys, ro)
     end
  | _ -> ty

module Defs =
  Set.Make
    (struct
	type t = Type.t * SeqSyntax.var list * SeqSyntax.body
	let compare = compare
      end)

let rec to_list defs =
  if Defs.is_empty defs then []
  else
    let def = Defs.choose defs in
    let defs = Defs.remove def defs in
    def :: to_list defs

(*
 * program transformation
 *)

(* generate_args : int -> var list *)
let rec generate_args n =
  if n <= 0 then []
  else
    ("y" ^ string_of_int n) :: (generate_args @@ n-1)

(* transform : Env.t -> int -> PiSyntax.pl -> Defs.t * SeqSyntax.body *)
(* We assume that each type in pl is already annotated correctly *)
let rec transform env level pl =
  match pl.loc_val with
  | PNil ->
     (Defs.empty, SSkip)
  | PIn(body) ->
     begin
       try
	 let tyx = Env.find body.x env in
	 match tyx with
	 | TChan(_, tys, _) ->
	    let env = Env.add_list body.ys tys env in
	    let (defs, prog) = transform env level body.pl in
	    (defs, sbst_nondet env body.ys prog)
	 | _ ->
	    raise @@ ConvErr("transform: Non-channel name on input")
       with
       | Not_found ->
	  raise @@ ConvErr("transform: A variable " ^ body.x ^
			     "is not found in environment")
     end
  | PRIn(body) ->
     begin
       try
	 let ty = Env.find body.x env in
	 match ty with
	 | TChan(Some(LInt(i)), tys, _) ->
	    let env = Env.add_list body.ys tys env in
	    let (defs, prog) = transform env i body.pl in
	    (Defs.add (ty, body.ys, sbst_nondet env body.ys prog) defs,
	     SSkip)
	 | _ ->
	    raise @@ ConvErr("transform: Not a well-typed channel")
       with
       | Not_found ->
	  raise @@ ConvErr("transform: variable " ^ body.x ^
			     " is not found in environment")
     end
  | POut(body) ->
     begin
       try
	 let ty = Env.find body.x env in
	 match ty with
	 | TChan(Some(LInt(i)), _, _) ->
	    if i < level then
	      transform env level body.pl
	    else if i = level then
	      let (defs, prog) = transform env level body.pl in
	      let f = SeqSyntax.make_funcsym ty in
	      let es = transform_els env body.els in
	      if Defs.exists (fun (ty', _, _) -> ty' = ty) defs then
		(defs, SSeq(SApp(f, es), prog))
	      else
		(* TODO(nekketsuuu): 効率化 *)
		(Defs.add (ty, generate_args @@ List.length es, SSkip) defs,
		 SSeq(SApp(f, es), prog))
	    else
	      raise @@ Nontermination("The level of " ^ body.x ^
					" is " ^ string_of_int i ^
					  "greater than " ^ string_of_int level)
	 | _ ->
	    raise @@ ConvErr("transform: not a well-typed channel")
       with
       | Not_found ->
	  raise @@ ConvErr("transform: variable " ^ body.x ^
			     " is not found in environment")
     end
  | PPar(body) ->
     let (defs1, prog1) = transform env level body.pl1 in
     let (defs2, prog2) = transform env level body.pl2 in
     (Defs.union defs1 defs2, SNDet(prog1, prog2))
  | PRes(body) ->
     begin
       match body.tyxo with
       | Some(tyx) ->
	  let env = Env.add body.x tyx env in
	  let (defs, prog) = transform env level body.pl in
	  (defs, sbst_nondet env [body.x] prog)
       | _ ->
	  raise @@ ConvErr("transform: No type information")
     end
  | PIf(body) ->
     let e = transform_el env body.el in
     let (defs1, prog1) = transform env level body.pl1 in
     let (defs2, prog2) = transform env level body.pl2 in
     (Defs.union defs1 defs2, SIf(e, prog1, prog2))
(* sbst_nondet : Env.t -> name list -> SeqSyntax.body -> SeqSyntax.body *)
and sbst_nondet env ys cont_prog =
  match ys with
  | [] -> cont_prog
  | y :: ys ->
     try
       let ty = Env.find y env in
       match ty with
       | TChan(_) ->
	  sbst_nondet env ys cont_prog
       | TBool ->
	  SSeq(SSbst(y, ty, ENDBool), sbst_nondet env ys cont_prog)
       | TInt ->
	  SSeq(SSbst(y, ty, ENDInt), sbst_nondet env ys cont_prog)
       | TUnit ->
	  (* TODO(nekketsuuu): これでいい? *)
	  sbst_nondet env ys cont_prog
       | TVar(_) ->
	  raise @@ ConvErr("sbst_nondet: a type variable remains")
     with
     | Not_found ->
	raise @@ ConvErr("sbst_nondet: variable " ^ y ^
			   " is not found in environment")
(* transform_els : PiSyntax.el list -> SeqSyntax.expr list *)
and transform_els env els =
  match els with
  | [] -> []
  | el :: els ->
       match el.loc_val with
       | EVar(x) ->
	  begin
	    try
	      let ty = Env.find x env in
	      match ty with
	      | TChan(_)
	      | TUnit ->
		 transform_els env els
	      | _ ->
		 (transform_el env el) :: (transform_els env els)
	    with
	    | Not_found ->
	       raise @@ ConvErr("transform_els: variable " ^ x ^
				  " is not found in environment")
	  end
       | EUnit ->
	  transform_els env els
       | _ ->
	  (transform_el env el) :: (transform_els env els)
(* transform_el : PiSyntax.el -> SeqSyntax.expr *)
and transform_el env el =
  match el.loc_val with
  | EVar(x) ->
     begin
       try
	 let ty = Env.find x env in
	 match ty with
	 | TChan(_) ->
	    raise @@ ConvErr("transform_el : channel type variable " ^ x)
	 | TUnit ->
	    raise @@ ConvErr("transform_el : unit type variable " ^ x)
	 | _ ->
	    EVar(x)
       with
       | Not_found ->
	  raise @@ ConvErr("transform_el: variable " ^ x ^
			     " is not found in environment")
     end
  | EUnit -> raise @@ ConvErr("transform_el: unit value")
  | EBool(b) -> EBool(b)
  | EInt(i)  -> EInt(i)
  | ENot(el) -> ENot(transform_el env el)
  | ENeg(el) -> ENeg(transform_el env el)
  | EAnd(el1, el2) -> EAnd(transform_el env el1, transform_el env el2)
  | EOr(el1, el2)  -> EOr(transform_el env el1, transform_el env el2)
  | EAdd(el1, el2) -> EAdd(transform_el env el1, transform_el env el2)
  | ESub(el1, el2) -> ESub(transform_el env el1, transform_el env el2)
  | EMul(el1, el2) -> EMul(transform_el env el1, transform_el env el2)
  | EDiv(el1, el2) -> EDiv(transform_el env el1, transform_el env el2)
  | EEq(el1, el2)  ->
     begin
       (*
	* Convert a comparison of
	*  - channels into nondeterministic bool value
	*  - units into true
	*)
       match el1.loc_val, el2.loc_val with
       | EVar(x1), EVar(x2) ->
	  begin
	    try
	      let ty1 = Env.find x1 env in
	      match ty1 with
	      | TChan(_) -> ENDBool
	      | TUnit    -> EBool(true)
	      | _ -> EEq(transform_el env el1, transform_el env el2)
	    with
	    | Not_found ->
	       raise @@ ConvErr("transform_el: variable " ^ x1 ^
				  " is not found in environment")
	  end
       | EVar(x), _
       | _, EVar(x) ->
	  begin
	    try
	      let ty = Env.find x env in
	      match ty with
	      | TUnit -> EBool(true)
	      | _ -> EEq(transform_el env el1, transform_el env el2)
	    with
	    | Not_found ->
	       raise @@ ConvErr("transform_el: variable " ^ x ^
				  " is not found in environment")
	  end
       | EUnit, _
       | _, EUnit ->
	  EBool(true)
       | _, _ ->
	  EEq(transform_el env el1, transform_el env el2)
     end
  | ELt(el1, el2)  -> ELt(transform_el env el1, transform_el env el2)
  | EGt(el1, el2)  -> EGt(transform_el env el1, transform_el env el2)
  | ELeq(el1, el2) -> ELeq(transform_el env el1, transform_el env el2)
  | EGeq(el1, el2) -> EGeq(transform_el env el1, transform_el env el2)

(* make_whole_program : Defs.t -> SeqSyntax.body -> SeqSyntax.program *)
let rec make_whole_program defs body =
  (make_defs defs, body)
and make_defs defs =
  if Defs.is_empty defs then []
  else
    let (ty, _, _) = Defs.choose defs in
    let funcs = Defs.filter (fun (ty', _, _) -> ty' = ty) defs in
    let defs = Defs.diff defs funcs in
    let funcs_list = to_list funcs in
    let n = List.length @@ (fun (_, ys, _) -> ys) @@ Defs.choose funcs in
    let args = generate_args n in
    let fsym = make_funcsym ty in
    let n = List.length funcs_list in
    let parent_def = (fsym, Some(ty), args,
		      make_parent_body fsym args n) in
    let local_defs = make_local_defs fsym funcs_list n in
    parent_def :: local_defs @ make_defs defs
and make_parent_body fsym args n : SeqSyntax.body =
  if n <= 0 then SSkip
  else if n = 1 then
    SApp(fsym ^ "_1", List.map (fun y -> EVar(y)) args)
  else
    SNDet(SApp(fsym ^ "_" ^ string_of_int n,
	       List.map (fun y -> EVar(y)) args),
	  make_parent_body fsym args (n-1))
and make_local_defs fsym funcs_list n : def list =
  if n <= 0 then []
  else
    let (_, local_args, local_body) = List.hd funcs_list in
    let def = (fsym ^ "_" ^ string_of_int n,
	       None,
	       local_args,
	       local_body) in
    def :: make_local_defs fsym (List.tl funcs_list) (n-1)

(*
 * main function
 *)

(* infer : PiSyntax.pl -> SeqSyntax.program *)
let rec infer pl : SeqSyntax.program =
  (* decide channel levels *)
  let lsym = gensym_level () in
  let l = LVar(lsym) in
  let c = infer_proc Env.empty l pl in
  let sbst = ConstraintsL.solve c in
  max_level := Type.min_level;
  annotate_level sbst pl;
  let (defs, prog) = transform Env.empty !max_level pl in
  make_whole_program defs prog
