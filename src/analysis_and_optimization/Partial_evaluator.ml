(* A partial evaluator for use in static analysis and optimization *)

open Core_kernel
open Mir_utils
open Middle

let apply_prefix_operator_int (op : string) i =
  Lit
    ( Int
    , Int.to_string
        ( match op with
        | "PPlus__" -> i
        | "PMinus__" -> -i
        | "PNot__" -> if i = 0 then 1 else 0
        | s -> raise_s [%sexp (s : string)] ) )

let apply_prefix_operator_real (op : string) i =
  Lit
    ( Real
    , Float.to_string
        ( match op with
        | "PPlus__" -> i
        | "PMinus__" -> -.i
        | s -> raise_s [%sexp (s : string)] ) )

let apply_operator_int (op : string) i1 i2 =
  Lit
    ( Int
    , Int.to_string
        ( match op with
        | "Plus__" -> i1 + i2
        | "Minus__" -> i1 - i2
        | "Times__" -> i1 * i2
        | "Divide__" -> i1 / i2
        | "Modulo__" -> i1 % i2
        | "Equals__" -> Bool.to_int (i1 = i2)
        | "NEquals__" -> Bool.to_int (i1 <> i2)
        | "Less__" -> Bool.to_int (i1 < i2)
        | "Leq__" -> Bool.to_int (i1 <= i2)
        | "Greater__" -> Bool.to_int (i1 > i2)
        | "Geq__" -> Bool.to_int (i1 >= i2)
        | s -> raise_s [%sexp (s : string)] ) )

let apply_arithmetic_operator_real (op : string) r1 r2 =
  Lit
    ( Real
    , Float.to_string
        ( match op with
        | "Plus__" -> r1 +. r2
        | "Minus__" -> r1 -. r2
        | "Times__" -> r1 *. r2
        | "Divide__" -> r1 /. r2
        | s -> raise_s [%sexp (s : string)] ) )

let apply_logical_operator_real (op : string) r1 r2 =
  Lit
    ( Int
    , Int.to_string
        ( match op with
        | "Equals__" -> Bool.to_int (r1 = r2)
        | "NEquals__" -> Bool.to_int (r1 <> r2)
        | "Less__" -> Bool.to_int (r1 < r2)
        | "Leq__" -> Bool.to_int (r1 <= r2)
        | "Greater__" -> Bool.to_int (r1 > r2)
        | "Geq__" -> Bool.to_int (r1 >= r2)
        | s -> raise_s [%sexp (s : string)] ) )

let get_indices length (indices : 'e index) =
  let make_range bot top =
    List.range ~start:`inclusive ~stop:`inclusive bot top
  in
  let get_int_value e =
    match e.expr with
    | Lit (Int, s) ->
        let i = int_of_string s in
        if i <= 0 || i > length then None else Some i
    | _ -> None
  in
  let get_int_values l =
    let l = List.map l ~f:get_int_value in
    if List.exists l ~f:(fun x -> x = None) then None
    else Some (List.map l ~f:(fun x -> Option.value_exn x))
  in
  let indices =
    match indices with
    | All -> Some (make_range 1 length)
    | Single e -> get_int_values [e]
    | Upfrom e ->
        Option.map (get_int_value e) ~f:(fun bot -> make_range bot length)
    | Downfrom e ->
        Option.map (get_int_value e) ~f:(fun top -> make_range 1 top)
    | Between (e1, e2) ->
        Option.map2 (get_int_value e1) (get_int_value e2) ~f:(fun bot top ->
            make_range bot top )
    | MultiIndex e -> (
      match e.expr with
      | FunApp (_, f, l) when f = string_of_internal_fn FnMakeArray ->
          get_int_values l
      | _ -> None )
  in
  Option.map indices ~f:(List.map ~f:(fun x -> x - 1))

let rec eval_expr (e : Middle.expr_typed_located) =
  let e = {e with expr= map_expr eval_expr e.expr} in
  { e with
    expr=
      ( match e.expr with
      | Var _ | Lit (_, _) -> e.expr
      | FunApp (t, f, l) ->
          let get_fun_or_op_rt_opt name l' =
            let argument_types =
              List.map ~f:(fun x -> (x.emeta.madlevel, x.emeta.mtype)) l'
            in
            try
              let op = Middle.operator_of_sexp (Sexp.of_string name) in
              operator_return_type op argument_types
            with _ -> Middle.stan_math_returntype name argument_types
          in
          let try_partially_evaluate_to e =
            match e with
            | FunApp (StanLib, f', l') -> (
              match get_fun_or_op_rt_opt f' l' with
              | Some _ -> FunApp (StanLib, f', l')
              | None -> FunApp (StanLib, f, l) )
            | e -> e
          in
          try_partially_evaluate_to
            ( match (f, l) with
            (* TODO: deal with tilde statements and unnormalized distributions properly here *)
            | ( "bernoulli_lpmf"
              , [ y
                ; { expr=
                      FunApp
                        ( StanLib
                        , "inv_logit"
                        , [ { expr=
                                FunApp
                                  ( StanLib
                                  , "Plus__"
                                  , [ alpha
                                    ; { expr=
                                          FunApp (StanLib, "Times__", [x; beta]); _
                                      } ] ); _ } ] ); _ } ] )
              when x.emeta.mtype = UMatrix ->
                FunApp
                  (StanLib, "bernoulli_logit_glm_lpmf", [y; x; alpha; beta])
            | ( "bernoulli_lpmf"
              , [ y
                ; { expr=
                      FunApp
                        ( StanLib
                        , "inv_logit"
                        , [ { expr=
                                FunApp
                                  ( StanLib
                                  , "Plus__"
                                  , [ { expr=
                                          FunApp (StanLib, "Times__", [x; beta]); _
                                      }
                                    ; alpha ] ); _ } ] ); _ } ] )
              when x.emeta.mtype = UMatrix ->
                FunApp
                  (StanLib, "bernoulli_logit_glm_lpmf", [y; x; alpha; beta])
            | ( "bernoulli_lpmf"
              , [ y
                ; { expr=
                      FunApp
                        ( StanLib
                        , "inv_logit"
                        , [{expr= FunApp (StanLib, "Times__", [x; beta]); _}] ); _
                  } ] )
              when x.emeta.mtype = UMatrix ->
                FunApp (StanLib, "bernoulli_logit_glm_lpmf", [y; x; zero; beta])
            | ( "bernoulli_logit_lpmf"
              , [ y
                ; { expr=
                      FunApp
                        ( StanLib
                        , "Plus__"
                        , [ alpha
                          ; {expr= FunApp (StanLib, "Times__", [x; beta]); _}
                          ] ); _ } ] )
              when x.emeta.mtype = UMatrix ->
                FunApp
                  (StanLib, "bernoulli_logit_glm_lpmf", [y; x; alpha; beta])
            | ( "bernoulli_logit_lpmf"
              , [ y
                ; { expr=
                      FunApp
                        ( StanLib
                        , "Plus__"
                        , [ {expr= FunApp (StanLib, "Times__", [x; beta]); _}
                          ; alpha ] ); _ } ] )
              when x.emeta.mtype = UMatrix ->
                FunApp
                  (StanLib, "bernoulli_logit_glm_lpmf", [y; x; alpha; beta])
            | ( "bernoulli_logit_lpmf"
              , [y; {expr= FunApp (StanLib, "Times__", [x; beta]); _}] )
              when x.emeta.mtype = UMatrix ->
                FunApp (StanLib, "bernoulli_logit_glm_lpmf", [y; x; zero; beta])
            | ( "bernoulli_lpmf"
              , [y; {expr= FunApp (StanLib, "inv_logit", [alpha]); _}] ) ->
                FunApp (StanLib, "bernoulli_logit_lpmf", [y; alpha])
            | ( "bernoulli_rng"
              , [{expr= FunApp (StanLib, "inv_logit", [alpha]); _}] ) ->
                FunApp (StanLib, "bernoulli_logit_rng", [alpha])
            | ( "binomial_lpmf"
              , [y; {expr= FunApp (StanLib, "inv_logit", [n; alpha]); _}] ) ->
                FunApp (StanLib, "binomial_logit_lpmf", [y; n; alpha])
            | ( "categorical_lpmf"
              , [y; {expr= FunApp (StanLib, "inv_logit", [alpha]); _}] ) ->
                FunApp (StanLib, "categorical_logit_lpmf", [y; alpha])
            | ( "categorical_rng"
              , [{expr= FunApp (StanLib, "inv_logit", [alpha]); _}] ) ->
                FunApp (StanLib, "categorical_logit_rng", [alpha])
            | "columns_dot_product", [x; y]
              when compare_expr_typed_located x y = 0 ->
                FunApp (StanLib, "columns_dot_self", [x])
            | "dot_product", [x; y] when compare_expr_typed_located x y = 0 ->
                FunApp (StanLib, "dot_self", [x])
            | "inv", [{expr= FunApp (StanLib, "sqrt", l); _}] ->
                FunApp (StanLib, "inv_sqrt", l)
            | "inv", [{expr= FunApp (StanLib, "square", [x]); _}] ->
                FunApp (StanLib, "inv_square", [x])
            | ( "log"
              , [ { expr=
                      FunApp
                        ( StanLib
                        , "Minus__"
                        , [ {expr= Lit (Int, "1"); _}
                          ; {expr= FunApp (StanLib, "exp", [x]); _} ] ); _ } ]
              ) ->
                FunApp (StanLib, "log1m_exp", [x])
            | ( "log"
              , [ { expr=
                      FunApp
                        ( StanLib
                        , "Minus__"
                        , [ {expr= Lit (Int, "1"); _}
                          ; {expr= FunApp (StanLib, "inv_logit", [x]); _} ] ); _
                  } ] ) ->
                FunApp (StanLib, "log1m_inv_logit", [x])
            | ( "log"
              , [ { expr=
                      FunApp
                        (StanLib, "Minus__", [{expr= Lit (Int, "1"); _}; x]); _
                  } ] ) ->
                FunApp (StanLib, "log1m", [x])
            | ( "log"
              , [ { expr=
                      FunApp
                        ( StanLib
                        , "Plus__"
                        , [ {expr= Lit (Int, "1"); _}
                          ; {expr= FunApp (StanLib, "exp", [x]); _} ] ); _ } ]
              ) ->
                FunApp (StanLib, "log1p_exp", [x])
            | ( "log"
              , [ { expr=
                      FunApp (StanLib, "Plus__", [{expr= Lit (Int, "1"); _}; x]); _
                  } ] ) ->
                FunApp (StanLib, "log1p", [x])
            | ( "log"
              , [ { expr=
                      FunApp
                        ( StanLib
                        , "fabs"
                        , [{expr= FunApp (StanLib, "determinant", [x]); _}] ); _
                  } ] ) ->
                FunApp (StanLib, "log_determinant", [x])
            | ( "log"
              , [ { expr=
                      FunApp
                        ( StanLib
                        , "Minus__"
                        , [ {expr= FunApp (StanLib, "exp", [x]); _}
                          ; {expr= FunApp (StanLib, "exp", [y]); _} ] ); _ } ]
              ) ->
                FunApp (StanLib, "log_diff_exp", [x; y])
            (* TODO: log_mix?*)
            | "log", [{expr= FunApp (StanLib, "falling_factorial", l); _}] ->
                FunApp (StanLib, "log_falling_factorial", l)
            | "log", [{expr= FunApp (StanLib, "rising_factorial", l); _}] ->
                FunApp (StanLib, "log_rising_factorial", l)
            | "log", [{expr= FunApp (StanLib, "inv_logit", l); _}] ->
                FunApp (StanLib, "log_inv_logit", l)
            | "log", [{expr= FunApp (StanLib, "softmax", l); _}] ->
                FunApp (StanLib, "log_softmax", l)
            | ( "log"
              , [ { expr=
                      FunApp
                        ( StanLib
                        , "sum"
                        , [{expr= FunApp (StanLib, "exp", l); _}] ); _ } ] ) ->
                FunApp (StanLib, "log_sum_exp", l)
            | ( "log"
              , [ { expr=
                      FunApp
                        ( StanLib
                        , "Plus__"
                        , [ {expr= FunApp (StanLib, "exp", [x]); _}
                          ; {expr= FunApp (StanLib, "exp", [y]); _} ] ); _ } ]
              ) ->
                FunApp (StanLib, "log_sum_exp", [x; y])
            | ( "multi_normal_lpdf"
              , [y; mu; {expr= FunApp (StanLib, "inverse", [tau]); _}] ) ->
                FunApp (StanLib, "multi_normal_prec_lpdf", [y; mu; tau])
            | ( "neg_binomial_2_lpmf"
              , [ y
                ; { expr=
                      FunApp
                        ( StanLib
                        , "exp"
                        , [ { expr=
                                FunApp
                                  ( StanLib
                                  , "Plus__"
                                  , [ alpha
                                    ; { expr=
                                          FunApp (StanLib, "Times__", [x; beta]); _
                                      } ] ); _ } ] ); _ }
                ; sigma ] )
              when x.emeta.mtype = UMatrix ->
                FunApp
                  ( StanLib
                  , "neg_binomial_2_log_glm_lpmf"
                  , [y; x; alpha; beta; sigma] )
            | ( "neg_binomial_2_lpmf"
              , [ y
                ; { expr=
                      FunApp
                        ( StanLib
                        , "exp"
                        , [ { expr=
                                FunApp
                                  ( StanLib
                                  , "Plus__"
                                  , [ { expr=
                                          FunApp (StanLib, "Times__", [x; beta]); _
                                      }
                                    ; alpha ] ); _ } ] ); _ }
                ; sigma ] )
              when x.emeta.mtype = UMatrix ->
                FunApp
                  ( StanLib
                  , "neg_binomial_2_log_glm_lpmf"
                  , [y; x; alpha; beta; sigma] )
            | ( "neg_binomial_2_lpmf"
              , [ y
                ; { expr=
                      FunApp
                        ( StanLib
                        , "exp"
                        , [{expr= FunApp (StanLib, "Times__", [x; beta]); _}] ); _
                  }
                ; sigma ] )
              when x.emeta.mtype = UMatrix ->
                FunApp
                  ( StanLib
                  , "neg_binomial_2_log_glm_lpmf"
                  , [y; x; zero; beta; sigma] )
            | ( "neg_binomial_2_log_lpmf"
              , [ y
                ; { expr=
                      FunApp
                        ( StanLib
                        , "Plus__"
                        , [ alpha
                          ; {expr= FunApp (StanLib, "Times__", [x; beta]); _}
                          ] ); _ }
                ; sigma ] )
              when x.emeta.mtype = UMatrix ->
                FunApp
                  ( StanLib
                  , "neg_binomial_2_log_glm_lpmf"
                  , [y; x; alpha; beta; sigma] )
            | ( "neg_binomial_2_log_lpmf"
              , [ y
                ; { expr=
                      FunApp
                        ( StanLib
                        , "Plus__"
                        , [ {expr= FunApp (StanLib, "Times__", [x; beta]); _}
                          ; alpha ] ); _ }
                ; sigma ] )
              when x.emeta.mtype = UMatrix ->
                FunApp
                  ( StanLib
                  , "neg_binomial_2_log_glm_lpmf"
                  , [y; x; alpha; beta; sigma] )
            | ( "neg_binomial_2_log_lpmf"
              , [y; {expr= FunApp (StanLib, "Times__", [x; beta]); _}; sigma] )
              when x.emeta.mtype = UMatrix ->
                FunApp
                  ( StanLib
                  , "neg_binomial_2_log_glm_lpmf"
                  , [y; x; zero; beta; sigma] )
            | ( "neg_binomial_2_lpmf"
              , [y; {expr= FunApp (StanLib, "exp", [eta]); _}; phi] ) ->
                FunApp (StanLib, "neg_binomial_2_log_lpmf", [y; eta; phi])
            | ( "neg_binomial_2_rng"
              , [{expr= FunApp (StanLib, "exp", [eta]); _}; phi] ) ->
                FunApp (StanLib, "neg_binomial_2_log_rng", [eta; phi])
            | ( "poisson_lpmf"
              , [ y
                ; { expr=
                      FunApp
                        ( StanLib
                        , "exp"
                        , [ { expr=
                                FunApp
                                  ( StanLib
                                  , "Plus__"
                                  , [ alpha
                                    ; { expr=
                                          FunApp (StanLib, "Times__", [x; beta]); _
                                      } ] ); _ } ] ); _ } ] )
              when x.emeta.mtype = UMatrix ->
                FunApp (StanLib, "poisson_log_glm_lpmf", [y; x; alpha; beta])
            | ( "normal_lpdf"
              , [ y
                ; { expr=
                      FunApp
                        ( StanLib
                        , "Plus__"
                        , [ alpha
                          ; {expr= FunApp (StanLib, "Times__", [x; beta]); _}
                          ] ); _ }
                ; sigma ] )
              when x.emeta.mtype = UMatrix ->
                FunApp
                  (StanLib, "normal_id_glm_lpdf", [y; x; alpha; beta; sigma])
            | ( "normal_lpdf"
              , [ y
                ; { expr=
                      FunApp
                        ( StanLib
                        , "Plus__"
                        , [ {expr= FunApp (StanLib, "Times__", [x; beta]); _}
                          ; alpha ] ); _ }
                ; sigma ] )
              when x.emeta.mtype = UMatrix ->
                FunApp
                  (StanLib, "normal_id_glm_lpdf", [y; x; alpha; beta; sigma])
            | ( "normal_lpdf"
              , [y; {expr= FunApp (StanLib, "Times__", [x; beta]); _}; sigma] )
              when x.emeta.mtype = UMatrix ->
                FunApp
                  (StanLib, "normal_id_glm_lpdf", [y; x; zero; beta; sigma])
            | ( "poisson_lpmf"
              , [ y
                ; { expr=
                      FunApp
                        ( StanLib
                        , "exp"
                        , [ { expr=
                                FunApp
                                  ( StanLib
                                  , "Plus__"
                                  , [ { expr=
                                          FunApp (StanLib, "Times__", [x; beta]); _
                                      }
                                    ; alpha ] ); _ } ] ); _ } ] )
              when x.emeta.mtype = UMatrix ->
                FunApp (StanLib, "poisson_log_glm_lpmf", [y; x; alpha; beta])
            | ( "poisson_lpmf"
              , [ y
                ; { expr=
                      FunApp
                        ( StanLib
                        , "exp"
                        , [{expr= FunApp (StanLib, "Times__", [x; beta]); _}] ); _
                  } ] )
              when x.emeta.mtype = UMatrix ->
                FunApp (StanLib, "poisson_log_glm_lpmf", [y; x; zero; beta])
            | ( "poisson_log_lpmf"
              , [ y
                ; { expr=
                      FunApp
                        ( StanLib
                        , "Plus__"
                        , [ alpha
                          ; {expr= FunApp (StanLib, "Times__", [x; beta]); _}
                          ] ); _ } ] )
              when x.emeta.mtype = UMatrix ->
                FunApp (StanLib, "poisson_log_glm_lpmf", [y; x; alpha; beta])
            | ( "poisson_log_lpmf"
              , [ y
                ; { expr=
                      FunApp
                        ( StanLib
                        , "Plus__"
                        , [ {expr= FunApp (StanLib, "Times__", [x; beta]); _}
                          ; alpha ] ); _ } ] )
              when x.emeta.mtype = UMatrix ->
                FunApp (StanLib, "poisson_log_glm_lpmf", [y; x; alpha; beta])
            | ( "poisson_log_lpmf"
              , [y; {expr= FunApp (StanLib, "Times__", [x; beta]); _}] )
              when x.emeta.mtype = UMatrix ->
                FunApp (StanLib, "poisson_log_glm_lpmf", [y; x; zero; beta])
            | "poisson_lpmf", [y; {expr= FunApp (StanLib, "exp", [eta]); _}] ->
                FunApp (StanLib, "poisson_log_lpmf", [y; eta])
            | "poisson_rng", [{expr= FunApp (StanLib, "exp", [eta]); _}] ->
                FunApp (StanLib, "poisson_log_rng", [eta])
            | "pow", [{expr= Lit (Int, "2"); _}; x] ->
                FunApp (StanLib, "exp2", [x])
            | "rows_dot_product", [x; y]
              when compare_expr_typed_located x y = 0 ->
                FunApp (StanLib, "rows_dot_self", [x])
            | "pow", [x; {expr= Lit (Int, "2"); _}] ->
                FunApp (StanLib, "square", [x])
            | "pow", [x; {expr= Lit (Real, "0.5"); _}]
             |( "pow"
              , [ x
                ; { expr=
                      FunApp
                        ( StanLib
                        , "Divide__"
                        , [{expr= Lit (Int, "1"); _}; {expr= Lit (Int, "2"); _}]
                        ); _ } ] ) ->
                FunApp (StanLib, "sqrt", [x])
            | "square", [{expr= FunApp (StanLib, "sd", [x]); _}] ->
                FunApp (StanLib, "variance", [x])
            | "sqrt", [{expr= Lit (Int, "2"); _}] ->
                FunApp (StanLib, "sqrt2", [])
            | ( "sum"
              , [ { expr=
                      FunApp
                        ( StanLib
                        , "square"
                        , [{expr= FunApp (StanLib, "Minus__", [x; y]); _}] ); _
                  } ] ) ->
                FunApp (StanLib, "squared_distance", [x; y])
            | "sum", [{expr= FunApp (StanLib, "diagonal", l); _}] ->
                FunApp (StanLib, "trace", l)
            | ( "trace"
              , [ { expr=
                      FunApp
                        ( StanLib
                        , "Times__"
                        , [ { expr=
                                FunApp
                                  ( StanLib
                                  , "Times__"
                                  , [ { expr=
                                          FunApp
                                            ( StanLib
                                            , "Times__"
                                            , [ d
                                              ; { expr=
                                                    FunApp
                                                      ( StanLib
                                                      , "transpose"
                                                      , [b] ); _ } ] ); _ }
                                    ; a ] ); _ }
                          ; c ] ); _ } ] )
              when compare_expr_typed_located b c = 0 ->
                FunApp (StanLib, "trace_gen_quad_form", [d; a; b])
            | "trace", [{expr= FunApp (StanLib, "quad_form", [a; b]); _}] ->
                FunApp (StanLib, "trace_quad_form", [a; b])
            | ( "Minus__"
              , [ {expr= Lit (Int, "1"); _}
                ; {expr= FunApp (StanLib, "erf", l); _} ] ) ->
                FunApp (StanLib, "erfc", l)
            | ( "Minus__"
              , [ {expr= Lit (Int, "1"); _}
                ; {expr= FunApp (StanLib, "erfc", l); _} ] ) ->
                FunApp (StanLib, "erf", l)
            | ( "Minus__"
              , [ {expr= FunApp (StanLib, "exp", l'); _}
                ; {expr= Lit (Int, "1"); _} ] ) ->
                FunApp (StanLib, "expm1", l')
            | "Plus__", [{expr= FunApp (StanLib, "Times__", [x; y]); _}; z]
             |"Plus__", [z; {expr= FunApp (StanLib, "Times__", [x; y]); _}] ->
                FunApp (StanLib, "fma", [x; y; z])
            | ( "Minus__"
              , [ {expr= Lit (Int, "1"); _}
                ; {expr= FunApp (StanLib, "gamma_p", l); _} ] ) ->
                FunApp (StanLib, "gamma_q", l)
            | ( "Minus__"
              , [ {expr= Lit (Int, "1"); _}
                ; {expr= FunApp (StanLib, "gamma_q", l); _} ] ) ->
                FunApp (StanLib, "gamma_p", l)
            | ( "Times__"
              , [ { expr=
                      FunApp
                        ( StanLib
                        , "matrix_exp"
                        , [{expr= FunApp (StanLib, "Times__", [t; a]); _}] ); _
                  }
                ; b ] )
              when t.emeta.mtype = UInt || t.emeta.mtype = UReal ->
                FunApp (StanLib, "scale_matrix_exp_multiply", [t; a; b])
            | ( "Times__"
              , [ { expr=
                      FunApp
                        ( StanLib
                        , "matrix_exp"
                        , [{expr= FunApp (StanLib, "Times__", [a; t]); _}] ); _
                  }
                ; b ] )
              when t.emeta.mtype = UInt || t.emeta.mtype = UReal ->
                FunApp (StanLib, "scale_matrix_exp_multiply", [t; a; b])
            | "Times__", [{expr= FunApp (StanLib, "matrix_exp", [a]); _}; b] ->
                FunApp (StanLib, "matrix_exp_multiply", [a; b])
            | "Times__", [x; {expr= FunApp (StanLib, "log", [y]); _}] ->
                FunApp (StanLib, "multiply_log", [x; y])
            | ( "Times__"
              , [ { expr=
                      FunApp
                        ( StanLib
                        , "transpose"
                        , [{expr= FunApp (StanLib, "diag_matrix", [v]); _}] ); _
                  }
                ; { expr=
                      FunApp
                        ( StanLib
                        , "Times__"
                        , [a; {expr= FunApp (StanLib, "diag_matrix", [w]); _}]
                        ); _ } ] )
              when compare_expr_typed_located v w = 0 ->
                FunApp (StanLib, "quad_form_diag", [a; v])
            | ( "Times__"
              , [ { expr=
                      FunApp
                        ( StanLib
                        , "Times__"
                        , [ { expr=
                                FunApp
                                  ( StanLib
                                  , "transpose"
                                  , [ { expr=
                                          FunApp (StanLib, "diag_matrix", [v]); _
                                      } ] ); _ }
                          ; a ] ); _ }
                ; {expr= FunApp (StanLib, "diag_matrix", [w]); _} ] )
              when compare_expr_typed_located v w = 0 ->
                FunApp (StanLib, "quad_form_diag", [a; v])
            | ( "Times__"
              , [ {expr= FunApp (StanLib, "transpose", [b]); _}
                ; {expr= FunApp (StanLib, "Times__", [a; c]); _} ] )
              when compare_expr_typed_located b c = 0 ->
                FunApp (StanLib, "quad_form", [a; b])
            | ( "Times__"
              , [ { expr=
                      FunApp
                        ( StanLib
                        , "Times__"
                        , [{expr= FunApp (StanLib, "transpose", [b]); _}; a] ); _
                  }
                ; c ] )
              when compare_expr_typed_located b c = 0 ->
                FunApp (StanLib, "quad_form", [a; b])
            | "Times__", [e1'; {expr= FunApp (StanLib, "diag_matrix", [v]); _}]
              ->
                FunApp (StanLib, "diag_post_multiply", [e1'; v])
            | "Times__", [{expr= FunApp (StanLib, "diag_matrix", [v]); _}; e2']
              ->
                FunApp (StanLib, "diag_pre_multiply", [v; e2'])
                (* Constant folding for operators *)
            | op, [{expr= Lit (Int, i); _}] -> (
              match op with
              | "PPlus_" | "PMinus__" | "PNot__" ->
                  apply_prefix_operator_int op (Int.of_string i)
              | _ -> FunApp (StanLib, op, l) )
            | op, [{expr= Lit (Real, r); _}] -> (
              match op with
              | "PPlus_" | "PMinus__" ->
                  apply_prefix_operator_real op (Float.of_string r)
              | _ -> FunApp (StanLib, op, l) )
            | op, [{expr= Lit (Int, i1); _}; {expr= Lit (Int, i2); _}] -> (
              match op with
              | "Plus__" | "Minus__" | "Times__" | "Divide__" | "Modulo__"
               |"Or__" | "And__" | "Equals__" | "NEquals__" | "Less__"
               |"Leq__" | "Greater__" | "Geq__" ->
                  apply_operator_int op (Int.of_string i1) (Int.of_string i2)
              | _ -> FunApp (StanLib, op, l) )
            | op, [{expr= Lit (Real, i1); _}; {expr= Lit (Real, i2); _}]
             |op, [{expr= Lit (Int, i1); _}; {expr= Lit (Real, i2); _}]
             |op, [{expr= Lit (Real, i1); _}; {expr= Lit (Int, i2); _}] -> (
              match op with
              | "Plus__" | "Minus__" | "Times__" | "Divide__" ->
                  apply_arithmetic_operator_real op (Float.of_string i1)
                    (Float.of_string i2)
              | "Or__" | "And__" | "Equals__" | "NEquals__" | "Less__"
               |"Leq__" | "Greater__" | "Geq__" ->
                  apply_logical_operator_real op (Float.of_string i1)
                    (Float.of_string i2)
              | _ -> FunApp (StanLib, op, l) )
            | _ -> FunApp (t, f, l) )
      | TernaryIf (e1, e2, e3) -> (
        match (e1, e2, e3) with
        | {expr= Lit (Int, "0"); _}, _, e3' -> e3'.expr
        | {expr= Lit (Int, _); _}, e2', _ -> e2'.expr
        | e1', e2', e3' -> TernaryIf (e1', e2', e3') )
      | EAnd (e1, e2) -> (
        match (e1, e2) with
        | {expr= Lit (Int, s1); _}, {expr= Lit (Int, s2); _} ->
            let i1, i2 = (Int.of_string s1, Int.of_string s2) in
            Lit (Int, Int.to_string (Bool.to_int (i1 <> 0 && i2 <> 0)))
        | {expr= Lit (Real, s1); _}, {expr= Lit (Real, s2); _} ->
            let r1, r2 = (Float.of_string s1, Float.of_string s2) in
            Lit (Int, Int.to_string (Bool.to_int (r1 <> 0. && r2 <> 0.)))
        | e1', e2' -> EAnd (e1', e2') )
      | EOr (e1, e2) -> (
        match (e1, e2) with
        | {expr= Lit (Int, s1); _}, {expr= Lit (Int, s2); _} ->
            let i1, i2 = (Int.of_string s1, Int.of_string s2) in
            Lit (Int, Int.to_string (Bool.to_int (i1 <> 0 || i2 <> 0)))
        | {expr= Lit (Real, s1); _}, {expr= Lit (Real, s2); _} ->
            let r1, r2 = (Float.of_string s1, Float.of_string s2) in
            Lit (Int, Int.to_string (Bool.to_int (r1 <> 0. || r2 <> 0.)))
        | e1', e2' -> EOr (e1', e2') )
      | Indexed (e, l) -> (
        (* TODO: deal with lists of indices *)
        match l with
        | [] -> Indexed (e, l)
        | [i] -> eval_indexed_expr e l i
        | _ -> Indexed (e, l) ) ) }

and eval_idx i = map_index eval_expr i

and eval_indexed_expr e l i =
  match e.expr with
  | FunApp (t, f, elts)
    when f = string_of_internal_fn FnMakeArray
         || f = string_of_internal_fn FnMakeRowVec -> (
    match get_indices (List.length elts) i with
    | None -> Indexed (e, l)
    | Some indices ->
        if List.length indices = 1 then
          (List.nth_exn elts (List.hd_exn indices)).expr
        else FunApp (t, f, List.map indices ~f:(List.nth_exn elts)) )
  | _ -> Indexed (e, l)

let eval_stmt_base = map_statement eval_expr (fun x -> x)
let eval_stmt = map_rec_stmt_loc eval_stmt_base
let eval_prog = map_prog eval_expr eval_stmt
