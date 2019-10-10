open Core_kernel
open Common
open Helpers

(** Fixed-point of statements *)
module Fixed = struct
  module First = Expr.Fixed

  module Pattern = struct
    type ('a, 'b) t =
      | Assignment of 'a lvalue * 'a
      | TargetPE of 'a
      | NRFunApp of Fun_kind.t * string * 'a list
      | Break
      | Continue
      | Return of 'a option
      | Skip
      | IfElse of 'a * 'b * 'b option
      | While of 'a * 'b
      | For of {loopvar: string; lower: 'a; upper: 'a; body: 'b}
      | Block of 'b list
      | SList of 'b list
      | Decl of
          { decl_adtype: UnsizedType.autodifftype
          ; decl_id: string
          ; decl_type: 'a Type.t }
    [@@deriving sexp, hash, map, fold, compare]

    and 'a lvalue = string * UnsizedType.t * 'a Index.t list
    [@@deriving sexp, hash, map, compare, fold]

    let pp pp_e pp_s ppf = function
      | Assignment ((assignee, _, idcs), rhs) ->
          Fmt.pf ppf {|@[<h>%a =@ %a;@]|} (Index.pp_indexed pp_e)
            (assignee, idcs) pp_e rhs
      | TargetPE expr ->
          Fmt.pf ppf {|@[<h>%a +=@ %a;@]|} pp_keyword "target" pp_e expr
      | NRFunApp (_, name, args) ->
          Fmt.pf ppf {|@[%s%a;@]|} name
            Fmt.(list pp_e ~sep:comma |> parens)
            args
      | Break -> pp_keyword ppf "break;"
      | Continue -> pp_keyword ppf "continue;"
      | Skip -> pp_keyword ppf ";"
      | Return (Some expr) ->
          Fmt.pf ppf {|%a %a;|} pp_keyword "return" pp_e expr
      | Return _ -> pp_keyword ppf "return;"
      | IfElse (pred, s_true, Some s_false) ->
          Fmt.pf ppf {|%a(%a) %a %a %a|} pp_builtin_syntax "if" pp_e pred pp_s
            s_true pp_builtin_syntax "else" pp_s s_false
      | IfElse (pred, s_true, _) ->
          Fmt.pf ppf {|%a(%a) %a|} pp_builtin_syntax "if" pp_e pred pp_s s_true
      | While (pred, stmt) ->
          Fmt.pf ppf {|%a(%a) %a|} pp_builtin_syntax "while" pp_e pred pp_s
            stmt
      | For {loopvar; lower; upper; body} ->
          Fmt.pf ppf {|%a(%s in %a:%a) %a|} pp_builtin_syntax "for" loopvar
            pp_e lower pp_e upper pp_s body
      | Block stmts ->
          Fmt.pf ppf {|{@;<1 2>@[<v>%a@]@;}|}
            Fmt.(list pp_s ~sep:Fmt.cut)
            stmts
      | SList stmts -> Fmt.(list pp_s ~sep:Fmt.cut |> vbox) ppf stmts
      | Decl {decl_adtype; decl_id; decl_type} ->
          Fmt.pf ppf {|%a%a %s;|} UnsizedType.pp_autodifftype decl_adtype
            (Type.pp pp_e) decl_type decl_id

    include Foldable.Make2 (struct
      type nonrec ('a, 'b) t = ('a, 'b) t

      let fold = fold
    end)
  end

  include Fixed.Make2 (First) (Pattern)
end

(** Statements with no meta-data *)
module NoMeta = struct
  module Meta = struct
    type t = unit [@@deriving compare, sexp, hash]

    let empty = ()
    let pp _ _ = ()
  end

  include Specialized.Make2 (Fixed) (Expr.NoMeta) (Meta)

  let remove_meta x = Fixed.map (fun _ -> ()) (fun _ -> ()) x
end

(** Statements with location information and types for contained expressions *)
module Located = struct
  module Meta = struct
    type t = (Location_span.t sexp_opaque[@compare.ignore])
    [@@deriving compare, sexp, hash]

    let empty = Location_span.empty
    let pp _ _ = ()
  end

  include Specialized.Make2 (Fixed) (Expr.Typed) (Meta)

  let loc_of x = Fixed.meta_of x

  (** This module acts as a temporary replace for the `stmt_loc_num` type that
  is currently used within `analysis_and_optimization`. 
  
  The original intent of the type was to provide explicit sharing of subterms.
  My feeling is that ultimately we either want to:
  - use the recursive type directly and rely on OCaml for sharing
  - provide the same interface as other `Specialized` modules so that
    the analysis code isn't aware of the particular representation we are using.
  *)
  module Non_recursive = struct
    type t =
      { pattern: (Expr.Typed.t, int) Fixed.Pattern.t
      ; meta: Meta.t sexp_opaque [@compare.ignore] }
    [@@deriving compare, sexp, hash]
  end
end

(** Statements with location information and labels. Contained expressions have
both are typed and labelled. *)
module Labelled = struct
  module Meta = struct
    type t =
      { loc: Location_span.t sexp_opaque [@compare.ignore]
      ; label: Label.Int_label.t [@compare.ignore] }
    [@@deriving compare, create, sexp, hash]

    let empty =
      create ~loc:Location_span.empty ~label:Label.Int_label.(prev init) ()

    let label {label; _} = label
    let loc {loc; _} = loc
    let pp _ _ = ()
  end

  include Specialized.Make2 (Fixed) (Expr.Labelled) (Meta)

  let label_of x = Meta.label @@ Fixed.meta_of x
  let loc_of x = Meta.loc @@ Fixed.meta_of x

  let label ?(init = Label.Int_label.init) (stmt : Located.t) : t =
    let lbl = ref init in
    let f Expr.Typed.Meta.({adlevel; type_; loc}) =
      let cur_lbl = !lbl in
      lbl := Label.Int_label.next cur_lbl ;
      Expr.Labelled.Meta.create ~type_ ~loc ~adlevel ~label:cur_lbl ()
    and g loc =
      let cur_lbl = !lbl in
      lbl := Label.Int_label.next cur_lbl ;
      Meta.create ~loc ~label:cur_lbl ()
    in
    Fixed.map f g stmt

  type associations =
    { exprs: Expr.Labelled.t Label.Int_label.Map.t
    ; stmts: t Label.Int_label.Map.t }

  let empty =
    {exprs= Label.Int_label.Map.empty; stmts= Label.Int_label.Map.empty}

  let rec associate ?init:(assocs = empty) (stmt : t) =
    associate_pattern
      { assocs with
        stmts=
          Label.Int_label.Map.add_exn assocs.stmts ~key:(label_of stmt)
            ~data:stmt }
      (Fixed.pattern_of stmt)

  and associate_pattern assocs = function
    | Fixed.Pattern.Break | Skip | Continue | Return None -> assocs
    | Return (Some e) | TargetPE e ->
        {assocs with exprs= Expr.Labelled.associate ~init:assocs.exprs e}
    | NRFunApp (_, _, args) ->
        { assocs with
          exprs=
            List.fold args ~init:assocs.exprs ~f:(fun accu x ->
                Expr.Labelled.associate ~init:accu x ) }
    | Assignment ((_, _, idxs), rhs) ->
        let exprs =
          Expr.Labelled.(
            associate rhs
              ~init:(List.fold ~f:associate_index ~init:assocs.exprs idxs))
        in
        {assocs with exprs}
    | IfElse (pred, body, None) | While (pred, body) ->
        let exprs = Expr.Labelled.associate ~init:assocs.exprs pred in
        associate ~init:{assocs with exprs} body
    | IfElse (pred, ts, Some fs) ->
        let exprs = Expr.Labelled.associate ~init:assocs.exprs pred in
        let assocs' = {assocs with exprs} in
        associate ~init:(associate ~init:assocs' ts) fs
    | Decl {decl_type; _} -> associate_possibly_sized_type assocs decl_type
    | For {lower; upper; body; _} ->
        let exprs =
          Expr.Labelled.(
            associate ~init:(associate ~init:assocs.exprs lower) upper)
        in
        let assocs' = {assocs with exprs} in
        associate ~init:assocs' body
    | Block xs | SList xs ->
        List.fold ~f:(fun accu x -> associate ~init:accu x) ~init:assocs xs

  and associate_possibly_sized_type assocs = function
    | Type.Sized st ->
        {assocs with exprs= SizedType.associate ~init:assocs.exprs st}
    | Unsized _ -> assocs
end

module Numbered = struct
  module Meta = struct
    type t = (int sexp_opaque[@compare.ignore])
    [@@deriving compare, sexp, hash]

    let empty = 0
    let from_int (i : int) : t = i
    let pp _ _ = ()
  end

  include Specialized.Make2 (Fixed) (Expr.Typed) (Meta)
end

module Helpers = struct
  let contains_fn fn ?(init = false) stmt =
    let fstr = Internal_fun.to_string fn in
    let rec aux accu stmt =
      match Fixed.pattern_of stmt with
      | NRFunApp (_, fname, _) when fname = fstr -> true
      | stmt_pattern ->
          Fixed.Pattern.fold_left ~init:accu stmt_pattern
            ~f:(fun accu expr -> Expr.Helpers.contains_fn fn ~init:accu expr)
            ~g:aux
    in
    aux init stmt

  (** [mkfor] returns a MIR For statement that iterates over the given expression
    [iteratee]. *)
  let mkfor upper bodyfn iteratee meta =
    let idx s =
      let meta =
        Expr.Typed.Meta.create ~type_:UInt ~loc:meta ~adlevel:DataOnly ()
      in
      let expr = Expr.Fixed.fix (meta, Var s) in
      Index.Single expr
    in
    let loopvar, reset = Gensym.enter () in
    let lower = Expr.Helpers.loop_bottom in
    let stmt =
      Fixed.Pattern.Block
        [bodyfn (Expr.Helpers.add_int_index iteratee (idx loopvar))]
    in
    reset () ;
    let body = Fixed.fix (meta, stmt) in
    let pattern = Fixed.Pattern.For {loopvar; lower; upper; body} in
    Fixed.fix (meta, pattern)

  (** [for_eigen unsizedtype...] generates a For statement that loops
    over the eigen types in the underlying [unsizedtype]; i.e. just iterating
    overarrays and running bodyfn on any eign types found within.

    We can call [bodyfn] directly on scalars and Eigen types;
    for Arrays we call mkfor but insert a
    recursive call into the [bodyfn] that will operate on the nested
    type. In this way we recursively create for loops that loop over
    the outermost layers first.
*)
  let rec for_eigen st bodyfn var smeta =
    match st with
    | SizedType.SInt | SReal | SVector _ | SRowVector _ | SMatrix _ ->
        bodyfn var
    | SArray (t, d) -> mkfor d (fun e -> for_eigen t bodyfn e smeta) var smeta

  (** [for_scalar unsizedtype...] generates a For statement that loops
    over the scalars in the underlying [unsizedtype].

    We can call [bodyfn] directly on scalars, make a direct For loop
    around Eigen types, or for Arrays we call mkfor but inserting a
    recursive call into the [bodyfn] that will operate on the nested
    type. In this way we recursively create for loops that loop over
    the outermost layers first.
*)
  let rec for_scalar st bodyfn var smeta =
    match st with
    | SizedType.SInt | SReal -> bodyfn var
    | SVector d | SRowVector d -> mkfor d bodyfn var smeta
    | SMatrix (d1, d2) ->
        mkfor d1 (fun e -> for_scalar (SRowVector d2) bodyfn e smeta) var smeta
    | SArray (t, d) -> mkfor d (fun e -> for_scalar t bodyfn e smeta) var smeta

  (** Exactly like for_scalar, but iterating through array dimensions in the 
  inverted order.*)
  let for_scalar_inv st bodyfn var smeta =
    (* (var : Expr.Typed.t) (smeta : Location_span.t) : Located.t = *)
    let invert_index_order e =
      match Expr.Fixed.pattern_of e with
      | Indexed (obj, idxs) -> {e with pattern= Indexed (obj, List.rev idxs)}
      | _ -> e
    in
    let rec go st bodyfn var smeta =
      match st with
      | SizedType.SArray (t, d) ->
          let bodyfn' var = mkfor d bodyfn var smeta in
          go t bodyfn' var smeta
      | SMatrix (d1, d2) ->
          let bodyfn' var = mkfor d1 bodyfn var smeta in
          go (SRowVector d2) bodyfn' var smeta
      | _ -> for_scalar st bodyfn var smeta
    in
    go st (Fn.compose bodyfn invert_index_order) var smeta

  let assign_indexed decl_type vident smeta varfn var =
    let indices = Expr.Helpers.collect_indices var in
    Fixed.fix (smeta, Assignment ((vident, decl_type, indices), varfn var))

  (* 
    let mock_stmt stmt = {stmt; smeta= no_span}
  let mir_int i = {expr= Lit (Int, string_of_int i); emeta= internal_meta}

  let mock_for i body =
    For
      { loopvar= "lv"
      ; lower= mir_int 0
      ; upper= mir_int i
      ; body= mock_stmt (Block [body]) }
    |> mock_stmt

  let%test "contains fn" =
    let f =
      mock_for 8
        (mock_for 9
          (mock_stmt
              (Assignment
                (("v", UInt, []), internal_funapp FnReadData [] internal_meta))))
    in
    contains_fn
      (string_of_internal_fn FnReadData)
      (mock_stmt (Block [f; mock_stmt Break]))

  let%test "contains nrfn" =
    let f =
      mock_for 8
        (mock_for 9
          (mock_stmt
              (NRFunApp (CompilerInternal, string_of_internal_fn FnWriteParam, []))))
    in
    contains_fn
      (string_of_internal_fn FnWriteParam)
      (mock_stmt
        (Block
            [ mock_stmt
                (NRFunApp
                  (CompilerInternal, string_of_internal_fn FnWriteParam, []))
            ; f ])) *)
end