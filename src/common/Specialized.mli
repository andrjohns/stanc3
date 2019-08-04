open Core_kernel

module type S = sig
  type t [@@deriving compare, sexp]

  module Meta : Meta.S
  include Pretty.S with type t := t
  include Comparator.S with type t := t

  include
    Comparable.S
    with type t := t
     and type comparator_witness := comparator_witness
end

module Make (X : Fix.S) (Meta : Meta.S) :
  S with type t = Meta.t X.t and module Meta := Meta

module Make2 (X : Fix.S2) (First : S) (Meta : Meta.S) :
  S with type t = (First.Meta.t, Meta.t) X.t and module Meta := Meta