(** Some plumbing for our compiler errors *)

val append_position_to_filename : string -> string -> string
(** Insert the line and column number string in a filename string before the first
    include, after the first filename *)

(** Our type of syntax error information *)
type parse_error =
  | Lexing of string * Lexing.position
  | Includes of string * Lexing.position
  | Parsing of string option * Lexing.position * Lexing.position

(** Exception for Syntax Errors *)
exception SyntaxError of parse_error

(** Exception [SemanticError (loc, msg)] indicates a semantic error with message
    [msg], occurring at location [loc]. *)
exception SemanticError of (Ast.location_span * string)

(** Exception for Fatal Errors. These should perhaps be left unhandled,
    so we can trace their origin. *)
exception FatalError of string

val report_syntax_error : parse_error -> unit
(** A syntax error message used when handling a SyntaxError *)

val report_semantic_error : Ast.location_span * string -> unit
(** A semantic error message used when handling a SemanticError *)

val semantic_error : loc:Ast.location_span -> string -> 'a
(** Throw a semantic error reported by the toplevel *)

val fatal_error : ?msg:string -> unit -> 'a
(** Throw a fatal error reported by the toplevel *)

val warn_deprecated : Lexing.position * string -> unit
(** Warn that a language construct is deprecated *)
