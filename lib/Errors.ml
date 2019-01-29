(** Setup of our compiler errors *)

open Core_kernel
open Ast

(** Insert the line and column number string in a filename string before the first
    include, after the first filename *)
let append_position_to_filename fname pos_string =
  let split_fname = Str.split (Str.regexp ", included from\nfile ") fname in
  match split_fname with
  | [] -> ""
  | fname1 :: fnames ->
      String.concat ~sep:", included from\nfile "
        ((fname1 ^ pos_string) :: fnames)

(** Our type of syntax error information *)
type parse_error =
  | Lexing of string * Lexing.position
  | Includes of string * Lexing.position
  | Parsing of string option * Lexing.position * Lexing.position

(** Exception for Syntax Errors *)
exception SyntaxError of parse_error

(** Exception [SemanticError (loc, msg)] indicates a semantic error with message
    [msg], occurring at location [loc]. *)
exception SemanticError of (location_span * string)

(** Exception [FatalError [msg]] indicates an error that should never happen with message
    [msg]. *)
exception FatalError of string

let position {Lexing.pos_fname; pos_lnum; pos_cnum; pos_bol} =
  let file = pos_fname in
  let line = pos_lnum in
  let column = pos_cnum - pos_bol in
  (file, line, column)

let error_context file line column =
  try
    let bare_file =
      List.hd_exn (Str.split (Str.regexp ", included from\nfile ") file)
    in
    let open In_channel in
    let input = create bare_file in
    for _ = 1 to line - 3 do
      ignore (input_line_exn input)
    done ;
    let open Printf in
    let line_2_before =
      if line > 2 then sprintf "%6d:  %s\n" (line - 2) (input_line_exn input)
      else ""
    in
    let line_before =
      if line > 1 then sprintf "%6d:  %s\n" (line - 1) (input_line_exn input)
      else ""
    in
    let our_line = sprintf "%6d:  %s\n" line (input_line_exn input) in
    let cursor_line = String.make (column + 9) ' ' ^ "^\n" in
    let line_after =
      try sprintf "%6d:  %s\n" (line + 1) (input_line_exn input) with _ -> ""
    in
    let line_2_after =
      try sprintf "%6d:  %s\n" (line + 2) (input_line_exn input) with _ -> ""
    in
    close input ;
    Some
      (sprintf
         "   -------------------------------------------------\n\
          %s%s%s%s%s%s   -------------------------------------------------\n"
         line_2_before line_before our_line cursor_line line_after line_2_after)
  with _ -> None

(** A syntax error message used when handling a SyntaxError *)
let report_syntax_error = function
  | Parsing (message, start_pos, end_pos) -> (
      let file, start_line, start_column = position start_pos in
      let _, curr_line, curr_column = position end_pos in
      let open Printf in
      let lines =
        if curr_line = start_line then sprintf "line %d" curr_line
        else sprintf "lines %d-%d" start_line curr_line
      in
      let columns =
        if curr_line = start_line then
          sprintf "columns %d-%d" start_column curr_column
        else sprintf "column %d" start_column
      in
      Printf.eprintf "\nSyntax error at file %s, parsing error:\n%!"
        (append_position_to_filename file
           (Printf.sprintf ", %s, %s" lines columns)) ;
      ( match error_context file curr_line curr_column with
      | None -> ()
      | Some line -> Printf.eprintf "%s\n" line ) ;
      match message with
      | None -> Printf.eprintf "\n"
      | Some error_message -> prerr_endline error_message )
  | Lexing (_, err_pos) ->
      let file, line, column = position err_pos in
      Printf.eprintf "\nSyntax error at file %s, lexing error:\n"
        (append_position_to_filename file
           (Printf.sprintf ", line %d, column %d" line (column - 1))) ;
      ( match error_context file line (column - 1) with
      | None -> ()
      | Some line -> Printf.eprintf "%s\n" line ) ;
      Printf.eprintf "Invalid character found. %s\n\n" ""
  | Includes (msg, err_pos) ->
      let file, line, column = position err_pos in
      Printf.eprintf "\nSyntax error at file %s, includes error:\n"
        (append_position_to_filename file
           (Printf.sprintf ", line %d, column %d" line column)) ;
      ( match error_context file line column with
      | None -> ()
      | Some line -> Printf.eprintf "%s\n" line ) ;
      Printf.eprintf "%s\n" msg

(** Print a location *)
let print_location_span loc ppf =
  match loc with {start_loc; end_loc} ->
    let begin_char = start_loc.colnum in
    let end_char = end_loc.colnum in
    let begin_line = start_loc.linenum in
    let filename = start_loc.filename in
    if String.length filename <> 0 then
      Format.fprintf ppf "file %s"
        (append_position_to_filename filename
           (Printf.sprintf ", line %d, columns %d-%d" begin_line begin_char
              end_char))
    else
      Format.fprintf ppf "line %d, columns %d-%d" (begin_line - 1) begin_char
        end_char

(** A semantic error message used when handling a SemanticError *)
let report_semantic_error (loc, msg) =
  match loc with {start_loc= {filename; linenum; colnum; _}; _} ->
    Format.eprintf "\n%s at %t:@\n" "Semantic error" (print_location_span loc) ;
    ( match error_context filename linenum colnum with
    | None -> ()
    | Some linenum -> Format.eprintf "%s\n" linenum ) ;
    Format.kfprintf
      (fun ppf -> Format.fprintf ppf "@.")
      Format.err_formatter "%s\n" msg

(* A semantic error reported by the toplevel *)
let semantic_error ~loc msg = raise (SemanticError (loc, msg))

(* A fatal error reported by the toplevel *)
let fatal_error ?(msg = "") _ =
  raise (FatalError ("This should never happen. Please file a bug. " ^ msg))

(* Warn that a language feature is deprecated *)
let warn_deprecated (pos, msg) =
  let file, line, column = position pos in
  Printf.eprintf "\nWarning: deprecated language construct used at file %s:\n"
    (append_position_to_filename file
       (Printf.sprintf ", line %d, column %d" line (column - 1))) ;
  ( match error_context file line (column - 1) with
  | None -> ()
  | Some line -> Printf.eprintf "%s\n" line ) ;
  Printf.eprintf "%s\n\n" msg
