open OpamParserTypes
module J = Yojson.Safe

module Versions = struct
  let omnomnom = "6b6d503d45f41a8a4f6af042e19d9278aa403c25"
end

let rec json_of_value : value -> J.t = function
  | String (_, x) | Ident (_, x) -> `String x
  | Bool (_, x) -> `Bool x
  | Int (_, x) -> `Int x
  | List (_, xs) -> `List (List.map json_of_value xs)
  | (Pfxop _ | Option _ | Relop _ | Prefix_relop _ | Group _ | Logop _ | Env_binding _) as x ->
      `String (OpamPrinter.value x)

let dep_of_value : value -> bool * string * string = function
  | String (_, p) -> (false, p, "*")
  | Option (_, String (_, p), [ Ident (_, ("with-test" | "with-doc" | "build")) ]) -> (true, p, "*")
  | Option (_, String (_, p), [ Prefix_relop (_, op, String (_, v)) ]) ->
      (false, p, OpamPrinter.relop op ^ " " ^ v)
  | p -> Printf.sprintf "Unknown package '%s'" (OpamPrinter.value p) |> failwith

let to_json fields : opamfile_item -> (string * J.t) list =
  let add_field k v = (k, json_of_value v) :: fields in
  function
  | Variable (_, (("version" | "license" | "homepage") as k), v) -> add_field k v
  | Variable (_, "synopsis", x) -> add_field "description" x
  | Variable (_, "depends", List (_, depends)) ->
      let add (main, dev) v =
        let is_dev, name, version = dep_of_value v in
        let name =
          match name with
          | "ocaml" -> name
          | _ -> "@opam/" ^ name
        in
        let dep = (name, `String version) in
        if is_dev then (main, dep :: dev) else (dep :: main, dev)
      in
      let main, dev = List.fold_left add ([], []) depends in
      ("devDependencies", `Assoc (List.rev dev))
      :: ("dependencies", `Assoc (List.rev main))
      :: fields
  | _ -> fields

let () =
  let { file_contents; _ } =
    match Sys.argv with
    | [| _; x |] -> OpamParser.file x
    | [| _ |] -> OpamParser.channel stdin "=stdin"
    | _ ->
        Printf.eprintf "%s: [FILE]\n%!" Sys.executable_name;
        exit 1
  in
  let fields = List.fold_left to_json [] file_contents in
  let json : J.t =
    `Assoc
      ( (("name", `String "illuaminate") :: List.rev fields)
      @ [ ( "esy",
            `Assoc
              [ ("build", `String "dune build -p #{self.name}");
                ("release", `Assoc [ ("includePackages", `List [ `String "root" ]) ])
              ] );
          ( "resolutions",
            `Assoc
              [ ( "@opam/omnomnom",
                  `String ("git://github.com/SquidDev/omnomnom:omnomnom.opam#" ^ Versions.omnomnom)
                )
              ] );
          ( "scripts",
            `Assoc
              [ ("test", `String "dune build @runtest -f");
                ("format", `String "dune build @fmt --auto-promote")
              ] )
        ] )
  in
  J.pretty_to_channel ~std:true stdout json;
  print_newline ()
