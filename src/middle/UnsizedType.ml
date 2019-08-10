open Core_kernel

type t = Mir_pattern.unsizedtype =
  | UInt
  | UReal
  | UVector
  | URowVector
  | UMatrix
  | UArray of t
  | UFun of (autodifftype * t) list * returntype
  | UMathLibraryFunction

and autodifftype = Mir_pattern.autodifftype = DataOnly | AutoDiffable

and returntype = Mir_pattern.returntype = Void | ReturnType of t
[@@deriving compare, hash, sexp]

let pp ppf x = Mir_pretty_printer.pp_unsizedtype ppf x
let pp_returntype ppf x = Mir_pretty_printer.pp_returntype ppf x
let pp_autodifftype ppf x = Mir_pretty_printer.pp_autodifftype ppf x
let uint = UInt
let ureal = UReal
let uvector = UVector
let urowvector = URowVector
let umatrix = UMatrix
let ufun args ty = UFun (args, ReturnType ty)
let ufun_void args = UFun (args, Void)
let umathlibfun = UMathLibraryFunction
let uarray uty = UArray uty

let autodifftype_can_convert at1 at2 =
  match (at1, at2) with DataOnly, AutoDiffable -> false | _ -> true

let check_of_same_type_mod_conv name t1 t2 =
  if String.is_prefix name ~prefix:"assign_" then t1 = t2
  else
    match (t1, t2) with
    | UReal, UInt -> true
    | UFun (l1, rt1), UFun (l2, rt2) ->
        rt1 = rt2
        && List.for_all
             ~f:(fun x -> x = true)
             (List.map2_exn
                ~f:(fun (at1, ut1) (at2, ut2) ->
                  ut1 = ut2 && autodifftype_can_convert at2 at1 )
                l1 l2)
    | _ -> t1 = t2

let rec check_of_same_type_mod_array_conv name t1 t2 =
  match (t1, t2) with
  | UArray t1elt, UArray t2elt ->
      check_of_same_type_mod_array_conv name t1elt t2elt
  | _ -> check_of_same_type_mod_conv name t1 t2

let check_compatible_arguments_mod_conv name args1 args2 =
  List.length args1 = List.length args2
  && List.for_all
       ~f:(fun y -> y = true)
       (List.map2_exn
          ~f:(fun sign1 sign2 ->
            check_of_same_type_mod_conv name (snd sign1) (snd sign2)
            && autodifftype_can_convert (fst sign1) (fst sign2) )
          args1 args2)

let is_real_type = function
  | UReal | UVector | URowVector | UMatrix
   |UArray UReal
   |UArray UVector
   |UArray URowVector
   |UArray UMatrix ->
      true
  | _ -> false

let is_int_type = function UInt | UArray UInt -> true | _ -> false
let is_fun_type = function UFun _ -> true | _ -> false

module Comparator = Comparator.Make (struct
  type nonrec t = t

  let compare = compare
  let sexp_of_t = sexp_of_t
end)

include Comparator

include Comparable.Make_using_comparator (struct
  type nonrec t = t

  let sexp_of_t = sexp_of_t
  let t_of_sexp = t_of_sexp

  include Comparator
end)