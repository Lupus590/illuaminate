open IlluaminateCore
open IlluaminateConfig
module StringMap = Map.Make (String)
open Syntax
open! Doc_syntax
module R = Resolve
module C = Doc_comment
module P = Doc_parser.Data
module VarTbl = R.VarTbl

module CommentCollection = Hashtbl.Make (struct
  type t = C.comment

  let equal = ( == )

  let hash = Hashtbl.hash
end)

module Tag = struct
  let type_mismatch = Error.Tag.make Error.Warning "doc:type-mismatch"

  let kind_mismatch = Error.Tag.make Error.Error "doc:kind-mismatch"

  let all = [ kind_mismatch; type_mismatch ]
end

type state =
  { errs : Error.t;
    unused_comments : unit CommentCollection.t;
    comments : P.t;
    resolve : R.t;
    vars : value documented ref VarTbl.t;
    globals : value documented ref;
    mutable types : type_info documented StringMap.t
  }

let report state = Error.report state.errs

type result =
  | Named of module_info documented
  | Unnamed of
      { file : Span.filename;
        body : value documented;
        mod_types : type_info documented list;
        mod_kind : module_kind
      }

module Value = struct
  module Lift = Doc_abstract_syntax.Lift (Doc_comment) (Doc_syntax)

  let mk_ref (Reference.Reference x) = Reference.Unknown x

  let lift : Lift.t =
    { any_ref = mk_ref; type_ref = mk_ref; description = (fun (Description x) -> Description x) }

  let debug_name = function
    | Function _ as x -> "function" ^ get_suffix x
    | Expr _ as e -> "?" ^ get_suffix e
    | Table _ -> "table"
    | Type _ -> "type"
    | Unknown -> "unknown"
    | Undefined -> "undefined"

  let get_function : C.comment -> value option = function
    | { arguments = []; returns = []; throws = []; _ } -> None
    | { arguments; returns; throws; _ } ->
        let args = List.map (List.map (Lift.arg lift)) arguments
        and rets = List.map (List.map (Lift.return lift)) returns
        and throws = List.map (Lift.description lift) throws in
        Some (Function { args; rets; throws; has_self = false })

  let get_value ~state (comment : C.comment) =
    match (get_function comment, comment.type_info) with
    | None, None -> Unknown
    | Some x, None -> x
    | None, Some { type_name } -> Type { type_name; type_members = [] }
    | Some _, Some _ ->
        report state Tag.kind_mismatch comment.source "Term is marked as both a function and a type";
        Undefined

  let get_documented ~state (comment : C.comment) =
    { description = Option.map (Lift.description lift) comment.description;
      definition = comment.source;
      descriptor = get_value ~state comment;
      examples = List.map (Lift.example lift) comment.examples;
      see = List.map (Lift.see lift) comment.see;
      local = comment.local
    }
end

module Merge = struct
  let documented (merge : Span.t -> 'a -> 'b -> 'c) (implicit : 'a documented)
      (explicit : 'b documented) =
    { description =
        ( match implicit.description with
        | None -> explicit.description
        | Some _ -> implicit.description );
      definition = implicit.definition;
      descriptor = merge implicit.definition implicit.descriptor explicit.descriptor;
      examples = implicit.examples @ explicit.examples;
      see = implicit.see @ explicit.see;
      local = implicit.local || explicit.local
    }

  let value ~errs pos implicit explicit =
    match (explicit, implicit) with
    (* The trivial cases *)
    | Unknown, x | x, Unknown -> x
    | Undefined, _ | _, Undefined -> Undefined
    | Table x, Table y -> Table (x @ y) (* TODO: Merge keys *)
    | Function _, Function _ -> explicit (* TODO: Validate matching args *)
    | Expr { ty; value }, Expr other when ty = other.ty -> (
      (* Expressions of the same type are merged. We really need a better strategy for this - it's
         only designed to detect constants. *)
      match (value, other.value) with
      | Some v, Some ov when v = ov -> Expr { value; ty }
      | _ -> Expr { ty; value = None } )
    | Expr { ty = NilTy; _ }, x | x, Expr { ty = NilTy; _ } ->
        (* If someone has assigned to nil and something else, prioritise that definition. *)
        x
    | Table fields, Type { type_name; type_members }
    | Type { type_name; type_members }, Table fields ->
        (* If we've an index metafield, use that instead *)
        let fields =
          match List.assoc_opt "__index" fields with
          | Some { descriptor = Table fields; _ } -> fields
          | _ -> fields
        in
        Type
          { type_name;
            type_members =
              type_members
              @ ( fields
                |> List.map (fun (member_name, value) ->
                       let member_value, member_is_method =
                         match value.descriptor with
                         | Function { has_self = true; _ } -> (value, true)
                         | Function ({ args = [ ({ arg_name = "self"; _ } :: args) ]; _ } as f) ->
                             let v = Function { f with args = [ args ]; has_self = true } in
                             ({ value with descriptor = v }, true)
                         | _ -> (value, false)
                       in
                       { member_name; member_is_method; member_value }) )
          }
    | _ ->
        Printf.sprintf "Conflicting definitions, cannot merge `%s` and `%s`"
          (Value.debug_name implicit) (Value.debug_name explicit)
        |> Error.report errs Tag.kind_mismatch pos;
        explicit

  (** Merge two documented values. *)
  let doc_value ~errs = documented (value ~errs)

  let modules ~errs span left right =
    { mod_name = left.mod_name;
      mod_kind = left.mod_kind;
      mod_types = left.mod_types @ right.mod_types;
      mod_contents = value ~errs span left.mod_contents right.mod_contents
    }
end

module DropLocal = struct
  let rec value : value -> value = function
    | Table xs ->
        Table
          (List.filter_map
             (fun (k, v) ->
               if v.local then None else Some (k, { v with descriptor = value v.descriptor }))
             xs)
    | Type t -> Type (type_info t)
    | (Function _ | Expr _ | Unknown | Undefined) as v -> v

  and type_info { type_name; type_members } : type_info =
    { type_name;
      type_members =
        List.filter_map
          (fun ({ member_value = v; _ } as m) ->
            if v.local then None
            else Some { m with member_value = { v with descriptor = v.descriptor } })
          type_members
    }

  let mod_types =
    List.filter_map (fun v ->
        if v.local then None else Some { v with descriptor = type_info v.descriptor })
end

module Infer = struct
  (** Construct a simple documented node, which has no additional information. *)
  let simple_documented descriptor definition =
    { description = None; descriptor; definition; examples = []; see = []; local = false }

  (** Annotate a value with documentation comments. *)
  let document state ~before ~after value =
    let add_doc comment value =
      match comment with
      | Some comment when CommentCollection.mem state.unused_comments comment ->
          CommentCollection.remove state.unused_comments comment;
          Value.get_documented ~state comment |> Merge.doc_value ~errs:state.errs value
      | _ -> value
    in
    value |> add_doc before |> add_doc after

  (** Filter attached documentation comments and annotate a value with them. *)
  let documenting state ~before ~after (span : Span.t) value : value documented =
    (* Limit comments to ones directly before/after the current node and appropriately aligned with
       it. *)
    let before =
      match before with
      | ({ C.source; _ } as c) :: _
        when source.start_line = span.start_line
             || (source.finish_line = span.start_line - 1 && source.start_col = span.start_col) ->
          Some c
      | _ -> None
    and after =
      match after with
      | ({ C.source; _ } as c) :: _
        when source.finish_line = span.finish_line
             || (source.start_line = span.finish_line + 1 && source.start_col = span.start_col) ->
          Some c
      | _ -> None
    in
    document state ~before ~after value

  (** Annotate a value with documentation comments taken from a pair of nodes. *)
  let document_with state ~before ~after span value : value documented =
    let before, _ = P.comment before state.comments in
    let _, after = P.comment after state.comments in
    documenting state ~before ~after span value

  (** Annotate a value with documentation comments taken from a statement. *)
  let document_stmt state stmt value : value documented =
    document_with state ~before:(First.stmt.get stmt) ~after:(Last.stmt.get stmt)
      (Spanned.stmt stmt) value

  (** Add a {!R.var} to the current scope. *)
  let add_resolved_var state var def =
    (* Add this term to the type map. Oh boy, this is almost definitely wrong *)
    let update_type = function
      | { descriptor = Type ({ type_name; _ } as ty); _ } as def ->
          state.types <- StringMap.add type_name { def with descriptor = ty } state.types
      | _ -> ()
    in
    ( if not (VarTbl.mem state.vars var) then
      match var with
      | { kind = Global; name = "_ENV"; _ } -> VarTbl.add state.vars var state.globals
      | { kind = Global; _ } -> (
        match !(state.globals) with
        | { descriptor = Table fs; _ } as globals ->
            state.globals := { globals with descriptor = Table (fs @ [ (var.name, def) ]) }
        | _ -> () )
      | _ -> () );
    match VarTbl.find_opt state.vars var with
    | None ->
        VarTbl.add state.vars var (ref def);
        update_type def
    | Some existing ->
        let def = Merge.doc_value ~errs:state.errs !existing def in
        existing := def;
        update_type def

  (** Add a {!var} to the current scope. *)
  let add_var state var def = add_resolved_var state (R.get_definition var state.resolve) def

  (** Add a {!name} to the current scope. The definition is lazy, as it's not guaranteed we do
      anything with it.*)
  let add_name state var (def : _ Lazy.t) : unit =
    let rec go def = function
      | NVar var ->
          let var = R.get_usage var state.resolve in
          add_resolved_var state var.var (Lazy.force def)
      | NDot { tbl = Ref tbl; key; _ } ->
          Fun.flip go tbl
            ( lazy
              (let def = Lazy.force def in
               simple_documented (Doc_syntax.Table [ (Node.contents.get key, def) ]) def.definition)
              )
      | NLookup { tbl = Ref tbl; key = String { lit_value; _ }; _ } ->
          Fun.flip go tbl
            ( lazy
              (let def = Lazy.force def in
               simple_documented (Doc_syntax.Table [ (lit_value, def) ]) def.definition) )
      | _ -> ()
    in
    match var with
    | NVar var ->
        let var = R.get_definition var state.resolve in
        add_resolved_var state var (Lazy.force def)
    | NDot _ | NLookup _ -> go def var

  (** Add a {!function_name} to the current scope. *)
  let add_fname state var def : unit =
    let rec go def = function
      | FVar var -> add_resolved_var state (R.get_usage var state.resolve).var def
      | FDot { tbl; field; _ } | FSelf { tbl; meth = field; _ } ->
          simple_documented (Doc_syntax.Table [ (Node.contents.get field, def) ]) def.definition
          |> Fun.flip go tbl
    in
    match var with
    | FVar var -> add_resolved_var state (R.get_definition var state.resolve) def
    | FDot _ | FSelf _ -> go def var

  (** Infer the documented type of an expression. *)
  let rec infer_expr state expr =
    let simp x = simple_documented x (Spanned.expr expr) in
    match expr with
    | Fun { fun_args; fun_body; _ } -> infer_fun state fun_args fun_body |> simp
    | Table { table_body; _ } ->
        let fields = infer_table state table_body in
        Doc_syntax.Table fields |> simp
    | String { lit_value; _ } ->
        Expr
          { ty = Type_syntax.Builtin.string;
            value =
              ( if String.length lit_value < 32 then Printf.sprintf "%S" lit_value |> Option.some
              else None )
          }
        |> simp
    | Number { lit_node; _ } | Int { lit_node; _ } | MalformedNumber lit_node ->
        Expr { ty = Type_syntax.Builtin.number; value = Node.contents.get lit_node |> Option.some }
        |> simp
    | True _ -> Expr { ty = Type_syntax.Builtin.boolean; value = Some "true" } |> simp
    | False _ -> Expr { ty = Type_syntax.Builtin.boolean; value = Some "false" } |> simp
    | Nil _ -> Expr { ty = Type.NilTy; value = Some "nil" } |> simp
    | Ref v -> (
      match infer_name state v with
      | None -> simp Unknown
      | Some x -> !x )
    | _ -> simp Unknown

  and infer_var state v : value documented ref option =
    match (R.get_usage v state.resolve).var with
    | { kind = Global; name = "_ENV"; _ } -> Some state.globals
    | var -> VarTbl.find_opt state.vars var

  and infer_name state : name -> value documented ref option = function
    | NVar v -> infer_var state v
    | _ -> (* TODO *) None

  (** Get a documented table entry *)
  and infer_table state = function
    | [] -> []
    | ((RawPair { ident; value; _ } as p), sep) :: xs ->
        let before = First.table_item.get p
        and after =
          match sep with
          | None -> Last.table_item.get p
          | Some sep -> sep
        in
        let value =
          infer_expr state value |> document_with state ~before ~after (Spanned.table_item p)
        in
        (Node.contents.get ident, value) :: infer_table state xs
    | _ :: xs ->
        (* For now, we just skip all other table items. In the future it might be worth adding type
           hints or something. *)
        infer_table state xs

  (** Get the descriptor for a list of arguments *)
  and infer_fun state ?(has_self = false) args body =
    let get_name = function
      | DotArg _ -> "..."
      | NamedArg (Var v) -> Node.contents.get v
    in
    let get_arg arg =
      { arg_name = get_name arg; arg_opt = false; arg_type = None; arg_description = None }
    in
    infer_stmts state body |> ignore;
    Function { args = [ SepList0.map' get_arg args.args_args ]; rets = []; throws = []; has_self }

  (** Merge a statement's definition with an (optional) doc comment and apply it to the current
      scope. *)
  and infer_stmt state (node : stmt) =
    (* Oh goodness, this is horrible. We really need an actual data-flow algorithm here, so we can
       handle various Lua idioms correctly. This works (albeit weirdly) for now. *)
    match node with
    | Local { local_vars = Mono var; local_vals = Some (_, Mono (Ref (NVar def_var) as def)); _ } as
      s ->
        ( match infer_var state def_var with
        | None -> infer_expr state def |> document_stmt state s |> add_var state var
        | Some def ->
            def := document_stmt state s !def;
            let var = R.get_definition var state.resolve in
            VarTbl.add state.vars var def );
        None
    | Local { local_vars = Mono var; local_vals = Some (_, Mono def); _ } as s ->
        infer_expr state def |> document_stmt state s |> add_var state var;
        None
    | Local { local_vars = Mono var; local_vals = None; _ } as s ->
        simple_documented Unknown (Spanned.stmt s) |> document_stmt state s |> add_var state var;
        None
    | LocalFunction { localf_var; localf_args; localf_body; _ } as s ->
        simple_documented (infer_fun state localf_args localf_body) (Spanned.stmt s)
        |> document_stmt state s |> add_var state localf_var;
        None
    | AssignFunction { assignf_name; assignf_args; assignf_body; _ } as s ->
        let has_self =
          match assignf_name with
          | FVar _ | FDot _ -> false
          | FSelf _ -> true
        in
        simple_documented (infer_fun state ~has_self assignf_args assignf_body) (Spanned.stmt node)
        |> document_stmt state s |> add_fname state assignf_name;
        None
    | Assign { assign_vars = Mono var; assign_vals = Mono def; _ } as s ->
        lazy (infer_expr state def |> document_stmt state s) |> add_name state var;
        None
    | Return { return_vals = Some (Mono expr); _ } as s ->
        infer_expr state expr |> document_stmt state s |> Option.some
    | _ -> None

  and infer_stmts state = function
    | [] -> None
    | node :: xs ->
        let docs = infer_stmt state node and rest = infer_stmts state xs in
        CCOpt.( <+> ) docs rest

  let extract_module data program =
    let errs = Error.make () in
    let comments = Data.get program P.key data in
    let resolve = Data.get program R.key data in
    let env = ref (simple_documented (Doc_syntax.Table []) (Spanned.program program)) in
    let state =
      { errs;
        unused_comments = CommentCollection.create 16;
        comments;
        resolve;
        vars = VarTbl.create 16;
        globals = env;
        types = StringMap.empty
      }
    in
    P.comments comments |> List.iter (fun c -> CommentCollection.add state.unused_comments c ());

    let mod_kind, body =
      match infer_stmts state program.program with
      | Some x -> (Library, x)
      | None -> (Module, !env)
    in
    let body = { body with descriptor = DropLocal.value body.descriptor } in
    let module_comment =
      match P.comment (First.program.get program) state.comments |> fst |> CCList.last_opt with
      | Some ({ source; _ } as c)
        when source.start_col = 1 && source.start_line = 1
             && CommentCollection.mem state.unused_comments c ->
          CommentCollection.remove state.unused_comments c;
          Some c
      | _ -> None
    in
    let mod_types = StringMap.bindings state.types |> List.map snd |> DropLocal.mod_types in
    let result =
      match module_comment with
      | Some ({ module_info = Some { mod_name }; _ } as comment) ->
          let merge pos implicit body =
            let mod_contents = Merge.value ~errs:state.errs pos implicit body in
            { mod_name; mod_contents; mod_types; mod_kind }
          in
          Named (Value.get_documented ~state comment |> Merge.documented merge body)
      | Some ({ module_info = None; _ } as comment) ->
          let body = Value.get_documented ~state comment |> Merge.doc_value ~errs:state.errs body in
          Unnamed { body; mod_types; file = (Spanned.program program).filename; mod_kind }
      | None -> Unnamed { body; mod_types; file = (Spanned.program program).filename; mod_kind }
    in
    (state, result)

  let key = Data.key ~name:(__MODULE__ ^ ".Infer") extract_module
end

module Resolve = struct
  module Lift = Doc_abstract_syntax.Lift (Doc_syntax) (Doc_syntax)
  open! Reference

  type state =
    { modules : module_info documented Lazy.t StringMap.t;
      current_module : module_info documented
    }

  let resolve =
    let in_module_finders =
      [ (* Look up names within a module *)
        (fun { mod_name; mod_contents; _ } name is_type ->
          if is_type then None
          else
            match mod_contents with
            | Table fields ->
                List.find_opt (fun (k, _) -> k = name) fields
                |> Option.map (fun (_, { definition; _ }) ->
                       Internal { in_module = mod_name; name = Some name; definition })
            | _ -> None);
        (* Look up types within a module *)
        (fun { mod_name; mod_types; _ } name _ ->
          List.find_opt (fun ty -> ty.descriptor.type_name = name) mod_types
          |> Option.map (fun { definition; _ } ->
                 Internal { in_module = mod_name; name = Some ("ty-" ^ name); definition }));
        (* Look up methods within a module *)
        (fun { mod_name; mod_types; _ } name is_type ->
          if is_type then None
          else
            match String.index_opt name ':' with
            | None -> None
            | Some i ->
                let type_name = CCString.take i name and item_name = CCString.drop (i + 1) name in
                mod_types
                |> List.find_opt (fun ty -> ty.descriptor.type_name = type_name)
                |> CCOpt.flat_map (fun ty ->
                       List.find_opt
                         (fun { member_name; _ } -> member_name = item_name)
                         ty.descriptor.type_members)
                |> Option.map (fun { member_name; member_value; _ } ->
                       Internal
                         { in_module = mod_name;
                           name = Some ("ty-" ^ type_name ^ ":" ^ member_name);
                           definition = member_value.definition
                         }))
      ]
    in
    let finders =
      [ (* Find a term in this mod *)
        (fun { current_module; _ } name is_type ->
          CCList.find_map (fun f -> f current_module.descriptor name is_type) in_module_finders);
        (* Find a module with this name *)
        (fun { modules; _ } name is_type ->
          match StringMap.find_opt name modules with
          | _ when is_type -> None
          | Some (lazy { definition; _ }) ->
              Some (Internal { in_module = name; name = None; definition })
          | None -> None);
        (* Finds elements within modules. This tries foo.[bar.baz], then foo.bar.[baz], etc... *)
        (fun { modules; _ } name is_type ->
          let rec go i =
            match String.index_from_opt name i '.' with
            | None -> None
            | Some i ->
                let mod_name = CCString.take i name and item_name = CCString.drop (i + 1) name in
                StringMap.find_opt mod_name modules
                |> CCOpt.flat_map (fun (lazy { descriptor = modu; _ }) ->
                       CCList.find_map (fun f -> f modu item_name is_type) in_module_finders)
                |> CCOpt.or_lazy ~else_:(fun () -> go (i + 1))
          in
          go 0);
        (* Looks up a Lua name *)
        (fun _ name is_type ->
          match
            if is_type then Lua_reference.lookup_type name else Lua_reference.lookup_name name
          with
          | InManual section ->
              Some (External { name; url = Some (Lua_reference.manual_section section) })
          | Undocumented -> Some (External { name; url = None })
          | Unknown -> None)
      ]
    in
    (* Validate the reference is well-formed, resolve it, and return null if we can't *)
    fun context ~types_only name ->
      let is_ident c = c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') in
      if
        String.length name > 0
        && is_ident name.[String.length name - 1]
        && CCString.for_all (fun x -> is_ident x || x == '.' || x == ':') name
      then
        CCList.find_map (fun f -> f context name types_only) finders
        |> Option.value ~default:(Reference.Unknown name)
      else Unknown name

  let resolve_ref context ~types_only : reference -> reference = function
    | Unknown n -> resolve context ~types_only n
    | (External _ | Internal _) as r -> r

  let go_documented lift go_child { description; descriptor : 'a; definition; examples; see; local }
      =
    { description = Option.map (Lift.description lift) description;
      descriptor = go_child lift descriptor;
      definition;
      examples = List.map (Lift.example lift) examples;
      see = List.map (Lift.see lift) see;
      local
    }

  let rec go_value lift = function
    | Function { args; rets; throws; has_self } ->
        Function
          { args = List.map (List.map (Lift.arg lift)) args;
            rets = List.map (List.map (Lift.return lift)) rets;
            throws = List.map (Lift.description lift) throws;
            has_self
          }
    | Table fields ->
        Table (List.map (fun (name, field) -> (name, go_documented lift go_value field)) fields)
    | (Expr _ | Unknown | Undefined) as e -> e
    | Type _ -> failwith "Illegal nested type"

  let go_type lift { type_name; type_members } =
    let go_member { member_name; member_is_method; member_value } =
      { member_name; member_is_method; member_value = go_documented lift go_value member_value }
    in
    { type_name; type_members = List.map go_member type_members }

  let go_desc context (Description x) =
    let open Omd in
    let visit = function
      | Html ("illuaminate:ref", [ ("link", Some link) ], label) ->
          Some
            [ ( match resolve context ~types_only:false link with
              | Internal { in_module; name = None; _ } ->
                  Html ("illuaminate:ref", [ ("module", Some in_module) ], label)
              | Internal { in_module; name = Some name; _ } ->
                  Html ("illuaminate:ref", [ ("module", Some in_module); ("sec", Some name) ], label)
              | External { url = Some url; _ } ->
                  Html ("illuaminate:ref", [ ("href", Some url) ], label)
              | External { url = None; _ } -> Html ("illuaminate:ref", [], label)
              | Unknown _ -> Html ("illuaminate:ref", [ ("link", Some link) ], label) )
            ]
      | _ -> None
    in
    Description (Omd_representation.visit visit x)

  let go_module modules current_module to_resolve =
    let context = { modules; current_module } in
    let lift : Lift.t =
      { any_ref = resolve_ref context ~types_only:false;
        type_ref = resolve_ref context ~types_only:true;
        description = go_desc context
      }
    in
    go_documented lift
      (fun lift { mod_name; mod_kind; mod_contents; mod_types } ->
        { mod_name;
          mod_kind;
          mod_contents = go_value lift mod_contents;
          mod_types = List.map (go_documented lift go_type) mod_types
        })
      to_resolve
end

module Config = struct
  type t = { module_path : (string * string) list }

  let workspace = Category.create ~name:"doc" ~comment:"Controls documentation generation." ()

  let key =
    let term =
      let open Term in
      let parse_path p =
        let trimmed = CCString.drop_while (fun x -> x = '/') p in
        match CCString.Split.left ~by:"?" trimmed with
        | None -> Ok (trimmed, ".lua")
        | Some (path, ext) -> Ok (path, ext)
      and print_path (x, y) = x ^ y in
      let+ module_path =
        field ~name:"library-path"
          ~comment:
            "The path(s) where modules are located. This is used for guessing the module name of \
             files, it is ignored when an explicit @module annotation is provided."
          ~default:[]
          Converter.(list (atom ~ty:"path" parse_path print_path))
      in
      { module_path }
    in
    Category.add term workspace

  let get { Data.root; config } =
    let { module_path } = Schema.get key config in
    List.map (fun (p, ext) -> (Fpath.(root // v p), ext)) module_path
end

type t =
  { current_module : result;
    errors : Error.t;
    comments : unit CommentCollection.t;
    data : Data.t;
    contents : module_info documented option
  }

let errors { errors; _ } = Error.errors errors

let detached_comments ({ comments; _ } : t) = CommentCollection.to_seq_keys comments |> List.of_seq

let get_unresolved_module data program =
  let module_path = Data.get program Data.context data |> Config.get in
  match Data.get program Infer.key data |> snd with
  | Named m -> Some m
  | Unnamed { file; body; mod_types; mod_kind } ->
      let path = Fpath.v file.path in
      let get_name best (root, ext) =
        if not (Fpath.is_rooted ~root path) then best
        else
          let modu =
            Fpath.relativize ~root path |> Option.get |> Fpath.to_string
            |> CCString.chop_suffix ~suf:ext
            |> CCOpt.flat_map @@ fun path ->
               let name = String.map (fun c -> if c = '/' || c = '\\' then '.' else c) path in
               match best with
               | Some best when String.length best < String.length name -> None
               | _ -> Some name
          in
          CCOpt.(modu <+> best)
      in
      List.fold_left get_name None module_path
      |> Option.map @@ fun mod_name ->
         { body with
           descriptor = { mod_name; mod_contents = body.descriptor; mod_types; mod_kind }
         }

let unresolved_module = Data.key ~name:(__MODULE__ ^ ".unresolved") get_unresolved_module

let crunch_modules : module_info documented list -> module_info documented = function
  | [] -> failwith "Impossible"
  | x :: xs ->
      let errs = Error.make () in
      List.fold_left Merge.(documented (modules ~errs)) x xs

let get data program =
  let state, current_module = Data.get program Infer.key data in
  let contents =
    Data.get program unresolved_module data
    |> Option.map @@ fun current ->
       let all =
         List.fold_left
           (fun modules file ->
             match Data.get_for file unresolved_module data with
             | None -> modules
             | Some result ->
                 let name = result.descriptor.mod_name in
                 StringMap.update name
                   (fun x -> Some (result :: Option.value ~default:[] x))
                   modules)
           StringMap.empty (Data.files data)
       in
       let current_scope =
         (* Bring all other modules with the same name into scope if required. *)
         match StringMap.find_opt current.descriptor.mod_name all with
         | None -> current
         | Some all -> crunch_modules (if List.memq current all then all else current :: all)
       in
       let all = StringMap.map (fun x -> lazy (crunch_modules x)) all in
       Resolve.go_module all current_scope current
  in
  { current_module; data; contents; errors = state.errs; comments = state.unused_comments }

let key = Data.key ~name:__MODULE__ get

let get_module ({ contents; _ } : t) = contents

let get_modules data =
  List.fold_left
    (fun modules file ->
      match Data.get_for file key data |> get_module with
      | None -> modules
      | Some result ->
          let name = result.descriptor.mod_name in
          StringMap.update name (fun x -> Some (result :: Option.value ~default:[] x)) modules)
    StringMap.empty (Data.files data)
  |> StringMap.to_seq
  |> Seq.map (fun (_, x) -> crunch_modules x)
  |> List.of_seq
