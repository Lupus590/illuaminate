module Converter = struct
  type 'a t = 'a Parser.t * ('a -> Sexp.raw)

  let bool : bool t = (Parser.bool, fun x -> Atom (string_of_bool x))

  let string : string t = (Parser.string, fun x -> Atom x)

  let float : float t = (Parser.float, fun x -> Atom (string_of_float x))

  let int : int t = (Parser.int, fun x -> Atom (string_of_int x))

  let list (f, t) : 'a list t = (Parser.list f, fun x -> List (List.map t x))

  let atom ~ty parse print : 'a t = (Parser.atom_res ~ty parse, fun x -> Atom (print x))
end

type 'a body =
  | Field of
      { default : 'a;
        converter : 'a Converter.t
      }
  | Group of 'a t

and 'a t =
  | Node of
      { name : string;
        comment : string;
        body : 'a body
      }
  | Const : 'a -> 'a t
  | Map : ('a -> 'b) * 'a t -> 'b t
  | Pair : 'a t * 'b t -> ('a * 'b) t

let group ~name ~comment body = Node { name; comment; body = Group body }

let field ~name ~comment ~default converter =
  Node { name; comment; body = Field { default; converter } }

let unit = Const ()

let const x = Const x

let ( let+ ) node map = Map (map, node)

let ( and+ ) a b = Pair (a, b)

let rec default : type a. a t -> a = function
  | Node { body; _ } -> default_body body
  | Map (f, t) -> f (default t)
  | Pair (l, r) -> (default l, default r)
  | Const x -> x

and default_body : type a. a body -> a = function
  | Field { default; _ } -> default
  | Group g -> default g

let write_key out write_body body ~name ~comment prev =
  let open Format in
  (* Write 'prev' lines between the previous entry and this one. *)
  for _ = 1 to prev do
    pp_force_newline out ()
  done;
  (* Comment *)
  pp_print_string out ";; ";
  pp_print_string out comment;
  pp_force_newline out ();
  (* Value *)
  pp_open_box out 2;
  pp_print_string out "(";
  pp_print_string out name;
  write_body out body;
  pp_print_string out ")";
  pp_close_box out ();
  (* The next item should have one blank line. *)
  2

let rec write_term : type a. Format.formatter -> a t -> int -> int =
 fun out t prev ->
  match t with
  | Node { name; comment; body } -> write_key out write_group body ~name ~comment prev
  | Map (_, t) -> write_term out t prev
  | Pair (l, r) -> write_term out l prev |> write_term out r
  | Const _ -> prev

and write_group : 'a. Format.formatter -> 'a body -> unit =
 fun out t ->
  match t with
  | Field { default; converter = _, t } ->
      Format.pp_print_space out ();
      Sexp.pp out (t default)
  | Group g -> write_term out g 1 |> ignore

let write_default out term = write_term out term 0 |> ignore

let rec to_parser : type a. a t -> a Parser.fields =
  let open Parser in
  function
  | Node { name; body = Field { default; converter = parse, _ }; _ } ->
      let+ value = field_opt ~name parse in
      Option.value ~default value
  | Node { name; body = Group body; _ } ->
      let+ value = field_opt ~name (to_parser body |> fields) in
      Option.value ~default:(default body) value
  | Const k -> Parser.const k
  | Map (f, x) -> ( let+ ) (to_parser x) f
  | Pair (x, y) -> ( and+ ) (to_parser x) (to_parser y)

module Repr = struct
  type 'a repr =
    | ReprNode of
        { value : 'a;
          is_default : bool
        }
    | ReprConst of 'a
    | ReprMap : ('a -> 'b) * 'a repr * 'b -> 'b repr
    | ReprPair : 'a repr * 'b repr * ('a * 'b) -> ('a * 'b) repr

  let value : type a. a repr -> a = function
    | ReprNode { value; _ } -> value
    | ReprConst x -> x
    | ReprMap (_, _, x) -> x
    | ReprPair (_, _, x) -> x

  let rec default : type a. a t -> a repr = function
    | Node { body = Field { default; _ }; _ } -> ReprNode { value = default; is_default = true }
    | Node { body = Group g; _ } -> default g
    | Const x -> ReprConst x
    | Map (f, x) ->
        let x = default x in
        ReprMap (f, x, f (value x))
    | Pair (l, r) ->
        let l = default l and r = default r in
        ReprPair (l, r, (value l, value r))

  let rec to_repr_parser : type a. a t -> a repr Parser.fields =
    let open Parser in
    function
    | Node { name; body = Field { default; converter = parse, _ }; _ } -> (
        let+ value = field_opt ~name parse in
        match value with
        | None -> ReprNode { value = default; is_default = true }
        | Some value -> ReprNode { value; is_default = false } )
    | Node { name; body = Group body; _ } -> (
        let+ value = field_opt ~name (to_repr_parser body |> fields) in
        match value with
        | None -> default body
        | Some v -> v )
    | Const k -> Parser.const (ReprConst k)
    | Map (f, x) ->
        let+ x = to_repr_parser x in
        ReprMap (f, x, f (value x))
    | Pair (l, r) ->
        let+ l = to_repr_parser l and+ r = to_repr_parser r in
        ReprPair (l, r, (value l, value r))

  (** Performs a right-biased merge of two reprs *)
  let rec merge : type a. a repr -> a repr -> a repr =
   fun l r ->
    match (l, r) with
    | ReprNode _, ReprNode { is_default = true; _ } -> l
    | ReprNode _, ReprNode _ -> r
    | ReprConst l, ReprConst r when l == r -> ReprConst l
    | ReprConst _, ReprConst _ -> invalid_arg "Mismatch (different constants)"
    | ReprPair (x, y, _), ReprPair (x', y', _) ->
        let x = merge x x' and y = merge y y' in
        ReprPair (x, y, (value x, value y))
    | ReprMap (f, x, _), ReprMap (g, y, _) when f == Obj.magic g ->
        let x = merge x (Obj.magic y) in
        ReprMap (f, x, f (value x))
    | ReprMap _, ReprMap _ -> invalid_arg "Mismatch (different map functions)"
    (* Missing cases *)
    | ReprNode _, (ReprConst _ | ReprMap _ | ReprPair _) ->
        invalid_arg "Mismatch (node and something else)"
    | ReprConst _, (ReprNode _ | ReprMap _ | ReprPair _) ->
        invalid_arg "Mismatch (const and something else)"
    | ReprPair _, (ReprNode _ | ReprConst _ | ReprMap _) ->
        invalid_arg "Mismatch (pair and something else)"
    | ReprMap _, (ReprNode _ | ReprConst _ | ReprPair _) ->
        invalid_arg "Mismatch (pair and something else)"
end
