(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Ast
open Expression
open Pyre
open Statement

type t = {
  class_definitions: Class.t Node.t Identifier.Table.t;
  class_metadata: GlobalResolution.class_metadata Identifier.Table.t;
  modules: Module.t Reference.Table.t;
  implicit_submodules: int Reference.Table.t;
  order: ClassHierarchy.t;
  aliases: Type.alias Identifier.Table.t;
  globals: GlobalResolution.global Reference.Table.t;
  dependencies: Dependencies.t;
  undecorated_functions: Type.t Type.Callable.overload Reference.Table.t
}

module type Handler = sig
  val register_dependency : qualifier:Reference.t -> dependency:Reference.t -> unit

  val register_global
    :  qualifier:Reference.t ->
    reference:Reference.t ->
    global:GlobalResolution.global ->
    unit

  val register_undecorated_function
    :  reference:Reference.t ->
    annotation:Type.t Type.Callable.overload ->
    unit

  val set_class_definition : name:Identifier.t -> definition:Class.t Node.t -> unit

  val register_class_metadata : Identifier.t -> unit

  val register_alias : qualifier:Reference.t -> key:Identifier.t -> data:Type.alias -> unit

  val purge : ?debug:bool -> Reference.t list -> unit

  val class_definition : Identifier.t -> Class.t Node.t option

  val class_metadata : Identifier.t -> GlobalResolution.class_metadata option

  val register_module : Source.t -> unit

  val register_implicit_submodule : Reference.t -> unit

  val is_module : Reference.t -> bool

  val module_definition : Reference.t -> Module.t option

  val in_class_definition_keys : Identifier.t -> bool

  val aliases : Identifier.t -> Type.alias option

  val globals : Reference.t -> GlobalResolution.global option

  val undecorated_signature : Reference.t -> Type.t Type.Callable.overload option

  val dependencies : Reference.t -> Reference.Set.Tree.t option

  val local_mode : string -> Source.mode option

  val transaction : f:(unit -> 'a) -> unit -> 'a

  module DependencyHandler : Dependencies.Handler

  module TypeOrderHandler : ClassHierarchy.Handler
end

module UnresolvedAlias = struct
  type t = {
    qualifier: Reference.t;
    target: Reference.t;
    value: Expression.expression_t
  }
  [@@deriving sexp, compare, hash]
end

module ResolvedAlias = struct
  type t = {
    qualifier: Reference.t;
    name: Type.Primitive.t;
    annotation: Type.alias
  }
  [@@deriving sexp, compare, hash]

  let register (module Handler : Handler) { qualifier; name; annotation } =
    Handler.register_alias ~qualifier ~key:name ~data:annotation
end

let resolution (module Handler : Handler) () =
  let aliases = Handler.aliases in
  let class_hierarchy = (module Handler.TypeOrderHandler : ClassHierarchy.Handler) in
  let constructor ~resolution class_name =
    let instantiated = Type.Primitive class_name in
    Handler.class_definition class_name
    >>| AnnotatedClass.create
    >>| AnnotatedClass.constructor ~instantiated ~resolution
  in
  let generics ~resolution class_definition =
    AnnotatedClass.create class_definition |> AnnotatedClass.generics ~resolution
  in
  let is_protocol annotation =
    Type.split annotation
    |> fst
    |> Type.primitive_name
    >>= Handler.class_definition
    >>| AnnotatedClass.create
    >>| AnnotatedClass.is_protocol
    |> Option.value ~default:false
  in
  let attributes ~resolution annotation =
    match Annotated.Class.resolve_class ~resolution annotation with
    | None -> None
    | Some [] -> None
    | Some [{ instantiated; class_attributes; class_definition }] ->
        AnnotatedClass.attributes
          class_definition
          ~resolution
          ~transitive:true
          ~instantiated
          ~class_attributes
        |> Option.some
    | Some (_ :: _) ->
        (* These come from calling attributes on Unions, which are handled by solve_less_or_equal
           indirectly by breaking apart the union before doing the instantiate_protocol_parameters.
           Therefore, there is no reason to deal with joining the attributes together here *)
        None
  in
  let global reference =
    (* TODO (T41143153): We might want to properly support this by unifying attribute lookup logic
       for module and for class *)
    match Reference.last reference with
    | "__file__"
    | "__name__" ->
        let annotation =
          Annotation.create_immutable ~global:true Type.string |> Node.create_with_default_location
        in
        Some annotation
    | "__dict__" ->
        let annotation =
          Type.dictionary ~key:Type.string ~value:Type.Any
          |> Annotation.create_immutable ~global:true
          |> Node.create_with_default_location
        in
        Some annotation
    | _ -> Handler.globals reference
  in
  GlobalResolution.create
    ~class_hierarchy
    ~aliases
    ~module_definition:Handler.module_definition
    ~class_definition:Handler.class_definition
    ~class_metadata:Handler.class_metadata
    ~constructor
    ~undecorated_signature:Handler.undecorated_signature
    ~generics
    ~attributes
    ~is_protocol
    ~global
    ()


let connect_definition
    (module Handler : Handler)
    ~(resolution : GlobalResolution.t)
    ~definition:({ Node.value = { Class.name; bases; _ }; _ } as definition)
  =
  let (module Handler : ClassHierarchy.Handler) = (module Handler.TypeOrderHandler) in
  let annotated = Annotated.Class.create definition in
  (* We have to split the type here due to our built-in aliasing. Namely, the "list" and "dict"
     classes get expanded into parametric types of List[Any] and Dict[Any, Any]. *)
  let connect ~predecessor ~successor ~parameters =
    let annotations_tracked =
      Handler.contains (Handler.indices ()) predecessor
      && Handler.contains (Handler.indices ()) successor
    in
    let primitive_cycle =
      (* Primitive cycles can be introduced by meta-programming. *)
      String.equal predecessor successor
    in
    if annotations_tracked && not primitive_cycle then
      ClassHierarchy.connect (module Handler) ~predecessor ~successor ~parameters
  in
  let primitive = Reference.show name in
  ( match Annotated.Class.inferred_callable_type annotated ~resolution with
  | Some callable ->
      connect
        ~predecessor:primitive
        ~successor:"typing.Callable"
        ~parameters:(Concrete [Type.Callable callable])
  | None -> () );

  (* Register normal annotations. *)
  let register_supertype { Expression.Call.Argument.value; _ } =
    let value = Expression.delocalize value in
    match Node.value value with
    | Call _
    | Name _ -> (
        let supertype, parameters =
          (* While building environment, allow untracked to parse into primitives *)
          GlobalResolution.parse_annotation
            ~allow_untracked:true
            ~allow_invalid_type_parameters:true
            resolution
            value
          |> Type.split
        in
        match supertype with
        | Type.Top ->
            Statistics.event
              ~name:"superclass of top"
              ~section:`Environment
              ~normals:["unresolved name", Expression.show value]
              ()
        | Type.Primitive primitive when not (ClassHierarchy.contains (module Handler) primitive) ->
            Log.log ~section:`Environment "Superclass annotation %a is missing" Type.pp supertype
        | Type.Primitive supertype ->
            connect ~predecessor:primitive ~successor:supertype ~parameters
        | _ ->
            Log.log ~section:`Environment "Superclass annotation %a is missing" Type.pp supertype )
    | _ -> ()
  in
  let inferred_base = Annotated.Class.inferred_generic_base annotated ~resolution in
  inferred_base @ bases
  (* Don't register metaclass=abc.ABCMeta, etc. superclasses. *)
  |> List.filter ~f:(fun { Expression.Call.Argument.name; _ } -> Option.is_none name)
  |> List.iter ~f:register_supertype


let handler
    { class_definitions;
      class_metadata;
      modules;
      implicit_submodules;
      order;
      aliases;
      globals;
      dependencies;
      undecorated_functions
    }
  =
  let (module DependencyHandler : Dependencies.Handler) = Dependencies.handler dependencies in
  ( module struct
    module TypeOrderHandler = (val ClassHierarchy.handler order : ClassHierarchy.Handler)

    module DependencyHandler = DependencyHandler

    let register_dependency ~qualifier ~dependency =
      Log.log
        ~section:`Dependencies
        "Adding dependency from %a to %a"
        Reference.pp
        dependency
        Reference.pp
        qualifier;
      DependencyHandler.add_dependent ~qualifier dependency


    let register_global ~qualifier ~reference ~global =
      DependencyHandler.add_global_key ~qualifier reference;
      Hashtbl.set ~key:reference ~data:global globals


    let register_undecorated_function ~reference ~annotation =
      Hashtbl.set undecorated_functions ~key:reference ~data:annotation


    let set_class_definition ~name ~definition =
      let definition =
        match Hashtbl.find class_definitions name with
        | Some { Node.location; value = preexisting } ->
            { Node.location; value = Class.update preexisting ~definition:(Node.value definition) }
        | _ -> definition
      in
      Hashtbl.set class_definitions ~key:name ~data:definition


    let register_alias ~qualifier ~key ~data =
      DependencyHandler.add_alias_key ~qualifier key;
      Hashtbl.set ~key ~data aliases


    let purge ?(debug = false) qualifiers =
      let purge_table_given_keys table keys =
        List.iter ~f:(fun key -> Hashtbl.remove table key) keys
      in
      (* Dependents are handled differently from other keys, because in each other
       * instance, the path is the only one adding entries to the key. However, we can have
       *  both a.py and b.py import c.py, and thus have c.py in its keys. Therefore, when
       * purging a.py, we need to take care not to remove the c -> b dependent relationship. *)
      let purge_dependents keys =
        let remove_paths entry =
          entry
          >>| fun entry ->
          let qualifiers = Reference.Set.of_list qualifiers in
          Set.diff entry qualifiers
        in
        List.iter
          ~f:(fun key -> Hashtbl.change dependencies.Dependencies.dependents key ~f:remove_paths)
          keys
      in
      let purge_submodules qualifier =
        let rec do_purge = function
          | None -> ()
          | Some qualifier ->
              ( if not (Hashtbl.mem modules qualifier) then
                  let change = function
                    | None
                    | Some 0 ->
                        None
                    | Some count -> (
                      match count - 1 with
                      | 0 -> None
                      | _ as count -> Some count )
                  in
                  Hashtbl.change implicit_submodules qualifier ~f:change );
              do_purge (Reference.prefix qualifier)
        in
        do_purge (Reference.prefix qualifier)
      in
      let class_keys =
        List.concat_map
          ~f:(fun qualifier -> DependencyHandler.get_class_keys ~qualifier)
          qualifiers
      in
      purge_table_given_keys class_definitions class_keys;
      purge_table_given_keys class_metadata class_keys;
      List.concat_map ~f:(fun qualifier -> DependencyHandler.get_alias_keys ~qualifier) qualifiers
      |> purge_table_given_keys aliases;
      let global_keys =
        List.concat_map
          ~f:(fun qualifier -> DependencyHandler.get_global_keys ~qualifier)
          qualifiers
      in
      purge_table_given_keys globals global_keys;
      purge_table_given_keys undecorated_functions global_keys;
      List.concat_map
        ~f:(fun qualifier -> DependencyHandler.get_dependent_keys ~qualifier)
        qualifiers
      |> purge_dependents;
      DependencyHandler.clear_keys_batch qualifiers;
      List.iter ~f:purge_submodules qualifiers;
      List.iter ~f:(Hashtbl.remove modules) qualifiers;
      SharedMem.collect `aggressive;
      if debug then
        ClassHierarchy.check_integrity (ClassHierarchy.handler order)


    let class_definition annotation = Hashtbl.find class_definitions annotation

    let register_module ({ Source.qualifier; _ } as source) =
      Hashtbl.set ~key:qualifier ~data:(Module.create source) modules


    let register_implicit_submodule qualifier =
      match Hashtbl.mem modules qualifier with
      | true -> ()
      | false ->
          let update = function
            | None -> 1
            | Some count -> count + 1
          in
          Hashtbl.update implicit_submodules qualifier ~f:update


    let is_module name = Hashtbl.mem modules name || Hashtbl.mem implicit_submodules name

    let module_definition name =
      match Hashtbl.find modules name with
      | Some _ as result -> result
      | None -> (
        match Hashtbl.mem implicit_submodules name with
        | true -> Some (Module.create_implicit ())
        | false -> None )


    let in_class_definition_keys = Hashtbl.mem class_definitions

    let aliases = Hashtbl.find aliases

    let register_class_metadata class_name =
      let successors = ClassHierarchy.successors (module TypeOrderHandler) class_name in
      let in_test =
        let is_unit_test { Node.value = definition; _ } = Class.is_unit_test definition in
        List.filter_map successors ~f:(Hashtbl.find class_definitions)
        |> List.exists ~f:is_unit_test
      in
      let is_final =
        Hashtbl.find class_definitions class_name
        >>| (fun { Node.value = definition; _ } -> Class.is_final definition)
        |> Option.value ~default:false
      in
      let extends_placeholder_stub_class =
        Hashtbl.find class_definitions class_name
        >>| AnnotatedClass.create
        >>| AnnotatedClass.extends_placeholder_stub_class ~aliases ~module_definition
        |> Option.value ~default:false
      in
      Hashtbl.set
        class_metadata
        ~key:class_name
        ~data:{ is_test = in_test; successors; is_final; extends_placeholder_stub_class }


    let class_metadata = Hashtbl.find class_metadata

    let globals = Hashtbl.find globals

    let undecorated_signature = Hashtbl.find undecorated_functions

    let dependencies = DependencyHandler.dependents

    let local_mode _ = None

    let transaction ~f () = f ()
  end : Handler )


let dependencies (module Handler : Handler) = Handler.dependencies

let register_module (module Handler : Handler) source = Handler.register_module source

let register_implicit_submodules (module Handler : Handler) qualifier =
  let rec register_submodules = function
    | None -> ()
    | Some qualifier ->
        Handler.register_implicit_submodule qualifier;
        register_submodules (Reference.prefix qualifier)
  in
  register_submodules (Reference.prefix qualifier)


let register_class_definitions (module Handler : Handler) source =
  let order = (module Handler.TypeOrderHandler : ClassHierarchy.Handler) in
  let module Visit = Visit.MakeStatementVisitor (struct
    type t = Type.Primitive.Set.t

    let visit_children _ = true

    let statement { Source.qualifier; _ } new_annotations = function
      | { Node.location; value = Class ({ Class.name; _ } as definition) } ->
          let name = Reference.show name in
          let primitive = name in
          Handler.DependencyHandler.add_class_key ~qualifier name;
          Handler.set_class_definition ~name ~definition:{ Node.location; value = definition };
          if not (ClassHierarchy.contains order primitive) then
            ClassHierarchy.insert order primitive;
          Set.add new_annotations primitive
      | _ -> new_annotations
  end)
  in
  Visit.visit Type.Primitive.Set.empty source


let collect_aliases (module Handler : Handler) { Source.statements; qualifier; _ } =
  let rec visit_statement ~qualifier ?(in_class_body = false) aliases { Node.value; _ } =
    match value with
    | Assign { Assign.target = { Node.value = Name target; _ }; annotation; value; _ }
      when Expression.is_simple_name target -> (
        let target =
          let target = Expression.name_to_reference_exn target |> Reference.sanitize_qualified in
          if in_class_body then target else Reference.combine qualifier target
        in
        let target_annotation =
          Type.create
            ~aliases:Handler.aliases
            (Expression.from_reference ~location:Location.Reference.any target)
        in
        match Node.value value, annotation with
        | ( _,
            Some
              { Node.value =
                  Call
                    { callee =
                        { Node.value =
                            Name
                              (Name.Attribute
                                { base =
                                    { Node.value =
                                        Name
                                          (Name.Attribute
                                            { base =
                                                { Node.value = Name (Name.Identifier "typing"); _ };
                                              attribute = "Type";
                                              _
                                            });
                                      _
                                    };
                                  attribute = "__getitem__";
                                  _
                                });
                          _
                        };
                      arguments =
                        [ { Call.Argument.value =
                              { Node.value =
                                  Call
                                    { callee =
                                        { Node.value =
                                            Name
                                              (Name.Attribute
                                                { base =
                                                    { Node.value =
                                                        Name
                                                          (Name.Attribute
                                                            { base =
                                                                { Node.value =
                                                                    Name
                                                                      (Name.Identifier
                                                                        "mypy_extensions");
                                                                  _
                                                                };
                                                              attribute = "TypedDict";
                                                              _
                                                            });
                                                      _
                                                    };
                                                  attribute = "__getitem__";
                                                  _
                                                });
                                          _
                                        };
                                      _
                                    };
                                _
                              };
                            _
                          } ]
                    };
                _
              } ) ->
            if not (Type.is_top target_annotation) then
              { UnresolvedAlias.qualifier; target; value } :: aliases
            else
              aliases
        | ( _,
            Some
              ( { Node.value =
                    Name
                      (Name.Attribute
                        { base = { Node.value = Name (Name.Identifier "typing"); _ };
                          attribute = "Any";
                          _
                        });
                  _
                } as value ) ) ->
            if not (Type.is_top target_annotation) then
              { UnresolvedAlias.qualifier; target; value } :: aliases
            else
              aliases
        | Call _, None
        | Name _, None -> (
            let value = Expression.delocalize value in
            match Type.Variable.parse_declaration value with
            | Some variable ->
                Handler.register_alias
                  ~qualifier
                  ~key:(Reference.show target)
                  ~data:(Type.VariableAlias variable);
                aliases
            | None ->
                let value_annotation = Type.create ~aliases:Handler.aliases value in
                if
                  not
                    ( Type.is_top target_annotation
                    || Type.is_top value_annotation
                    || Type.equal value_annotation target_annotation )
                then
                  { UnresolvedAlias.qualifier; target; value } :: aliases
                else
                  aliases )
        | _ -> aliases )
    | Class { Class.name; body; _ } ->
        List.fold body ~init:aliases ~f:(visit_statement ~qualifier:name ~in_class_body:true)
    | Import { Import.from = Some _; imports = [{ Import.name; _ }] }
      when Reference.show name = "*" ->
        (* Don't register x.* as an alias when a user writes `from x import *`. *)
        aliases
    | Import { Import.from; imports } ->
        let from =
          match from >>| Reference.show with
          | None
          | Some "future.builtins"
          | Some "builtins" ->
              Reference.empty
          | Some from -> Reference.create from
        in
        let import_to_alias { Import.name; alias } =
          let qualified_name =
            match alias with
            | None -> Reference.combine qualifier name
            | Some alias -> Reference.combine qualifier alias
          in
          let original_name = Reference.combine from name in
          (* A module might import T and define a T that shadows it. In this case, we do not want
             to create the alias. *)
          if
            ClassHierarchy.contains
              (module Handler.TypeOrderHandler)
              (Reference.show qualified_name)
          then
            []
          else
            match Reference.as_list qualified_name, Reference.as_list original_name with
            | [single_identifier], [typing; identifier]
              when String.equal typing "typing" && String.equal single_identifier identifier ->
                (* builtins has a bare qualifier. Don't export bare aliases from typing. *)
                []
            | _ ->
                [ { UnresolvedAlias.qualifier;
                    target = qualified_name;
                    value =
                      Expression.from_reference ~location:Location.Reference.any original_name
                  } ]
        in
        List.rev_append (List.concat_map ~f:import_to_alias imports) aliases
    | _ -> aliases
  in
  List.fold ~init:[] ~f:(visit_statement ~qualifier) statements


let resolve_alias (module Handler : Handler) { UnresolvedAlias.qualifier; target; value } =
  let order = (module Handler.TypeOrderHandler : ClassHierarchy.Handler) in
  let target_primitive_name = Reference.show target in
  let value_annotation =
    match Type.create ~aliases:Handler.aliases value with
    | Type.Variable variable ->
        if Type.Variable.Unary.contains_subvariable variable then
          Type.Any
        else
          Type.Variable { variable with variable = Reference.show target }
    | annotation -> annotation
  in
  let dependencies = String.Hash_set.create () in
  let module TrackedTransform = Type.Transform.Make (struct
    type state = unit

    let visit_children_before _ = function
      | Type.Optional Bottom -> false
      | _ -> true


    let visit_children_after = false

    let visit _ annotation =
      let new_state, transformed_annotation =
        match annotation with
        | Type.Parametric { name = primitive; _ }
        | Primitive primitive ->
            let reference =
              match Node.value (Type.expression (Type.Primitive primitive)) with
              | Expression.Name name when Expression.is_simple_name name ->
                  Expression.name_to_reference_exn name
              | _ -> Reference.create "typing.Any"
            in
            let module_definition = Handler.module_definition in
            if Module.from_empty_stub ~reference ~module_definition then
              (), Type.Any
            else if
              ClassHierarchy.contains order primitive
              || Handler.is_module (Reference.create primitive)
            then
              (), annotation
            else
              let _ = Hash_set.add dependencies primitive in
              (), annotation
        | _ -> (), annotation
      in
      { Type.Transform.transformed_annotation; new_state }
  end)
  in
  let _, annotation = TrackedTransform.visit () value_annotation in
  if Hash_set.is_empty dependencies then
    Result.Ok
      { ResolvedAlias.qualifier;
        name = target_primitive_name;
        annotation = Type.TypeAlias annotation
      }
  else
    Result.Error (Hash_set.to_list dependencies)


let register_aliases (module Handler : Handler) sources =
  Type.Cache.disable ();
  let register_aliases unresolved =
    let resolution_dependency = String.Table.create () in
    let worklist = Queue.create () in
    Queue.enqueue_all worklist unresolved;
    let rec fixpoint () =
      match Queue.dequeue worklist with
      | None -> ()
      | Some unresolved ->
          let _ =
            match resolve_alias (module Handler) unresolved with
            | Result.Error dependencies ->
                let add_dependency =
                  let update_dependency = function
                    | None -> [unresolved]
                    | Some entries -> unresolved :: entries
                  in
                  String.Table.update resolution_dependency ~f:update_dependency
                in
                List.iter dependencies ~f:add_dependency
            | Result.Ok ({ ResolvedAlias.name; _ } as resolved) -> (
                ResolvedAlias.register (module Handler) resolved;
                match Hashtbl.find resolution_dependency name with
                | Some entries ->
                    Queue.enqueue_all worklist entries;
                    Hashtbl.remove resolution_dependency name
                | None -> () )
          in
          fixpoint ()
    in
    fixpoint ()
  in
  List.concat_map ~f:(collect_aliases (module Handler)) sources |> register_aliases;
  Type.Cache.enable ()


let register_undecorated_functions
    (module Handler : Handler)
    (resolution : GlobalResolution.t)
    source
  =
  let module Visit = Visit.MakeStatementVisitor (struct
    type t = unit

    let visit_children = function
      | { Node.value = Define _; _ } ->
          (* inner functions are not globals *)
          false
      | _ -> true


    let statement _ _ { Node.value; location } =
      match value with
      | Class definition -> (
          let annotation =
            AnnotatedClass.create { Node.value = definition; location }
            |> AnnotatedClass.inferred_callable_type ~resolution
          in
          match annotation with
          | Some { Type.Callable.implementation; overloads = []; _ } ->
              Handler.register_undecorated_function
                ~reference:definition.Class.name
                ~annotation:implementation
          | _ -> () )
      | Define ({ Define.signature = { Statement.Define.name; _ }; _ } as define) ->
          if Define.is_overloaded_method define then
            ()
          else
            Handler.register_undecorated_function
              ~reference:name
              ~annotation:(Annotated.Callable.create_overload ~resolution define)
      | _ -> ()
  end)
  in
  Visit.visit () source


let register_values
    (module Handler : Handler)
    (resolution : GlobalResolution.t)
    ({ Source.statements; qualifier; _ } as source)
  =
  let qualified_reference reference =
    let reference =
      let builtins = Reference.create "builtins" in
      if Reference.is_strict_prefix ~prefix:builtins reference then
        Reference.drop_prefix ~prefix:builtins reference
      else
        reference
    in
    Reference.sanitize_qualified reference
  in
  let module CollectCallables = Visit.MakeStatementVisitor (struct
    type t = Type.Callable.t Node.t list Reference.Map.t

    let visit_children = function
      | { Node.value = Define _; _ } ->
          (* inner functions are not globals *)
          false
      | _ -> true


    let statement { Source.qualifier; _ } callables statement =
      let collect_callable ~name callables callable =
        Handler.DependencyHandler.add_function_key ~qualifier name;

        (* Register callable global. *)
        let change callable = function
          | None -> Some [callable]
          | Some existing -> Some (existing @ [callable])
        in
        Map.change callables name ~f:(change callable)
      in
      match statement with
      | { Node.location;
          value = Define ({ Statement.Define.signature = { name; parent; _ }; _ } as define)
        } ->
          let parent =
            if Define.is_class_method define then
              parent
              >>= fun reference -> Some (Type.Primitive (Reference.show reference)) >>| Type.meta
            else
              None
          in
          Annotated.Callable.apply_decorators ~resolution ~location define
          |> (fun overload -> [Define.is_overloaded_method define, overload])
          |> Annotated.Callable.create ~resolution ~parent ~name:(Reference.show name)
          |> Node.create ~location
          |> collect_callable ~name callables
      | _ -> callables
  end)
  in
  let register_callables ~key ~data =
    assert (not (List.is_empty data));
    let location = List.hd_exn data |> Node.location in
    data
    |> List.map ~f:Node.value
    |> Type.Callable.from_overloads
    >>| (fun callable -> Type.Callable callable)
    >>| Annotation.create_immutable ~global:true
    >>| Node.create ~location
    >>| (fun global -> Handler.register_global ~qualifier ~reference:key ~global)
    |> ignore
  in
  CollectCallables.visit Reference.Map.empty source |> Map.iteri ~f:register_callables;

  (* Register meta annotations for classes. *)
  let module Visit = Visit.MakeStatementVisitor (struct
    type t = unit

    let visit_children _ = true

    let statement { Source.qualifier; _ } _ = function
      | { Node.location; value = Class { Class.name; _ } } ->
          (* Register meta annotation. *)
          let primitive = Type.Primitive (Reference.show name) in
          let global =
            Annotation.create_immutable
              ~global:true
              ~original:(Some Type.Top)
              (Type.meta primitive)
            |> Node.create ~location
          in
          Handler.register_global ~qualifier ~reference:(qualified_reference name) ~global
      | _ -> ()
  end)
  in
  Visit.visit () source |> ignore;
  let rec visit statement =
    match statement with
    | { Node.value = If { If.body; orelse; _ }; _ } ->
        (* TODO(T28732125): Properly take an intersection here. *)
        List.iter ~f:visit body;
        List.iter ~f:visit orelse
    | { Node.value = Assign { Assign.target; annotation; value; _ }; _ } ->
        let annotation, explicit =
          match annotation with
          | Some ({ Node.value; _ } as annotation) ->
              let annotation =
                match value with
                | Name name when Expression.is_simple_name name -> Expression.delocalize annotation
                | _ -> annotation
              in
              Type.create ~aliases:Handler.aliases annotation, true
          | None ->
              let annotation =
                try GlobalResolution.resolve_literal resolution value with
                | _ -> Type.Top
              in
              annotation, false
        in
        let rec register_assign ~target ~annotation =
          let register ~location reference annotation =
            let reference = qualified_reference (Reference.combine qualifier reference) in
            (* Don't register attributes or chained accesses as globals *)
            if Reference.length (Reference.drop_prefix ~prefix:qualifier reference) = 1 then
              let register_global global =
                Node.create ~location global
                |> fun global -> Handler.register_global ~qualifier ~reference ~global
              in
              let exists = Option.is_some (Handler.globals reference) in
              if explicit then
                Annotation.create_immutable ~global:true annotation |> register_global
              else if not exists then
                (* Treat literal globals as having been explicitly annotated. *)
                let original =
                  if Type.is_partially_typed annotation then Some Type.Top else None
                in
                Annotation.create_immutable ~global:true ~original annotation |> register_global
              else
                ()
          in
          match target.Node.value, annotation with
          | Name name, _ when Expression.is_simple_name name ->
              register
                ~location:target.Node.location
                (Expression.name_to_reference_exn name)
                annotation
          | Tuple elements, Type.Tuple (Type.Bounded (Concrete parameters))
            when List.length elements = List.length parameters ->
              List.map2_exn
                ~f:(fun target annotation -> register_assign ~target ~annotation)
                elements
                parameters
              |> ignore
          | Tuple elements, Type.Tuple (Type.Unbounded parameter) ->
              List.map ~f:(fun target -> register_assign ~target ~annotation:parameter) elements
              |> ignore
          | Tuple elements, _ ->
              List.map ~f:(fun target -> register_assign ~target ~annotation:Type.Top) elements
              |> ignore
          | _ -> ()
        in
        register_assign ~target ~annotation
    | _ -> ()
  in
  List.iter ~f:visit statements


let connect_type_order (module Handler : Handler) resolution source =
  let module Visit = Visit.MakeStatementVisitor (struct
    type t = unit

    let visit_children _ = true

    let statement _ _ = function
      | { Node.location; value = Class definition } ->
          connect_definition
            (module Handler)
            ~resolution
            ~definition:(Node.create ~location definition)
      | _ -> ()
  end)
  in
  Visit.visit () source |> ignore


let register_dependencies (module Handler : Handler) source =
  let module Visit = Visit.MakeStatementVisitor (struct
    type t = unit

    let visit_children _ = true

    let statement { Source.qualifier; _ } _ = function
      | { Node.value = Import { Import.from; imports }; _ } ->
          let imports =
            let imports =
              match from with
              (* If analyzing from x import y, only add x to the dependencies. Otherwise, add all
                 dependencies. *)
              | None -> imports |> List.map ~f:(fun { Import.name; _ } -> name)
              | Some base_module -> [base_module]
            in
            let qualify_builtins import =
              match Reference.single import with
              | Some "builtins" -> Reference.empty
              | _ -> import
            in
            List.map imports ~f:qualify_builtins
          in
          List.iter
            ~f:(fun dependency -> Handler.register_dependency ~qualifier ~dependency)
            imports
      | _ -> ()
  end)
  in
  Visit.visit () source


let propagate_nested_classes (module Handler : Handler) source =
  let propagate ~qualifier ({ Statement.Class.name; _ } as definition) successors =
    let nested_class_names { Statement.Class.name; body; _ } =
      let extract_classes = function
        | { Node.value = Class { name = nested_name; _ }; _ } ->
            Some (Reference.drop_prefix nested_name ~prefix:name, nested_name)
        | _ -> None
      in
      List.filter_map ~f:extract_classes body
    in
    let create_alias added_sofar (stripped_name, full_name) =
      let alias = Reference.combine name stripped_name in
      if List.exists added_sofar ~f:(Reference.equal alias) then
        added_sofar
      else
        let primitive name = Type.Primitive (Reference.show name) in
        Handler.register_alias
          ~qualifier
          ~key:(Reference.show alias)
          ~data:(Type.TypeAlias (primitive full_name));
        alias :: added_sofar
    in
    let own_nested_classes = nested_class_names definition |> List.map ~f:snd in
    successors
    |> List.filter_map ~f:Handler.class_definition
    |> List.map ~f:Node.value
    |> List.concat_map ~f:nested_class_names
    |> List.fold ~f:create_alias ~init:own_nested_classes
    |> ignore
  in
  let module Visit = Visit.MakeStatementVisitor (struct
    type t = unit

    let visit_children _ = true

    let statement { Source.qualifier; _ } _ = function
      | { Node.value = Class ({ Class.name; _ } as definition); _ } ->
          Handler.class_metadata (Reference.show name)
          |> Option.iter ~f:(fun { GlobalResolution.successors; _ } ->
                 propagate ~qualifier definition successors)
      | _ -> ()
  end)
  in
  Visit.visit () source


let built_in_annotations =
  ["TypedDictionary"; "NonTotalTypedDictionary"] |> Type.Primitive.Set.of_list


module Builder = struct
  let create () =
    let class_definitions = Identifier.Table.create () in
    let class_metadata = Identifier.Table.create () in
    let modules = Reference.Table.create () in
    let implicit_submodules = Reference.Table.create () in
    let order = ClassHierarchy.Builder.default () in
    let aliases = Identifier.Table.create () in
    let globals = Reference.Table.create () in
    let dependencies = Dependencies.create () in
    let undecorated_functions = Reference.Table.create () in
    (* Register dummy module for `builtins` and `future.builtins`. *)
    let builtins = Reference.create "builtins" in
    Hashtbl.set modules ~key:builtins ~data:(Ast.Module.create_implicit ~empty_stub:true ());
    let future_builtins = Reference.create "future.builtins" in
    Hashtbl.set modules ~key:future_builtins ~data:(Ast.Module.create_implicit ~empty_stub:true ());

    (* Add `None` constant to globals. *)
    let annotation annotation =
      Annotation.create_immutable ~global:true annotation |> Node.create_with_default_location
    in
    Hashtbl.set globals ~key:(Reference.create "None") ~data:(annotation Type.none);
    Hashtbl.set globals ~key:(Reference.create "...") ~data:(annotation Type.Any);

    (* Add classes for `typing.Optional` and `typing.Undeclared` that are currently not encoded in
       the stubs. *)
    let add_special_class ~name ~bases ~metaclasses ~body =
      let definition =
        let create_base annotation =
          { Expression.Call.Argument.name = None; value = Type.expression annotation }
        in
        let create_metaclass annotation =
          { Expression.Call.Argument.name = Some (Node.create_with_default_location "metaclass");
            value = Type.expression annotation
          }
        in
        { Class.name = Reference.create name;
          bases = List.map bases ~f:create_base @ List.map metaclasses ~f:create_metaclass;
          body;
          decorators = [];
          docstring = None
        }
      in
      let successors =
        let successor annotation = annotation |> Type.split |> fst |> Type.primitive_name in
        List.filter_map bases ~f:successor @ ["object"]
      in
      Hashtbl.set
        ~key:name
        ~data:
          { GlobalResolution.successors;
            is_test = false;
            is_final = false;
            extends_placeholder_stub_class = false
          }
        class_metadata;
      Hashtbl.set ~key:name ~data:(Node.create_with_default_location definition) class_definitions
    in
    let t_self_expression = Name (Name.Identifier "TSelf") |> Node.create_with_default_location in
    List.iter
      ~f:(fun (name, bases, metaclasses, body) ->
        add_special_class ~name ~bases ~metaclasses ~body)
      [ "None", [], [], [];
        "typing.Optional", [], [], [];
        "typing.Undeclared", [], [], [];
        "typing.NoReturn", [], [], [];
        ( "typing.Type",
          [Type.parametric "typing.Generic" (Concrete [Type.variable "typing._T"])],
          [],
          [] );
        ( "typing.GenericMeta",
          [],
          [],
          [ Define
              { signature =
                  { name = Reference.create "typing.GenericMeta.__getitem__";
                    parameters =
                      [ { Parameter.name = "cls"; value = None; annotation = None }
                        |> Node.create_with_default_location;
                        { Parameter.name = "arg"; value = None; annotation = None }
                        |> Node.create_with_default_location ];
                    decorators = [];
                    docstring = None;
                    return_annotation = None;
                    async = false;
                    parent = Some (Reference.create "typing.GenericMeta")
                  };
                body = []
              }
            |> Node.create_with_default_location ] );
        "typing.Generic", [], [Type.Primitive "typing.GenericMeta"], [];
        ( "TypedDictionary",
          [Type.parametric "typing.Mapping" (Concrete [Type.string; Type.Any])],
          [],
          Type.TypedDictionary.defines ~t_self_expression ~total:true );
        ( "NonTotalTypedDictionary",
          [Type.Primitive "TypedDictionary"],
          [],
          Type.TypedDictionary.defines ~t_self_expression ~total:false ) ];

    (* Register hardcoded aliases. *)
    Hashtbl.set
      aliases
      ~key:"typing.DefaultDict"
      ~data:(Type.TypeAlias (Type.Primitive "collections.defaultdict"));
    Hashtbl.set aliases ~key:"None" ~data:(Type.TypeAlias (Type.Optional Type.Bottom));

    (* This is broken in typeshed:
       https://github.com/python/typeshed/pull/991#issuecomment-288160993 *)
    Hashtbl.set aliases ~key:"PathLike" ~data:(Type.TypeAlias (Type.Primitive "_PathLike"));
    Hashtbl.set aliases ~key:"TSelf" ~data:(Type.TypeAlias (Type.variable "_PathLike"));
    ClassHierarchy.insert (ClassHierarchy.handler order) "typing_extensions.Literal";
    { class_definitions;
      class_metadata;
      modules;
      implicit_submodules;
      order;
      aliases;
      globals;
      dependencies;
      undecorated_functions
    }


  let copy
      { class_definitions;
        class_metadata;
        modules;
        implicit_submodules;
        order;
        aliases;
        globals;
        dependencies;
        undecorated_functions
      }
    =
    { class_definitions = Hashtbl.copy class_definitions;
      class_metadata = Hashtbl.copy class_metadata;
      modules = Hashtbl.copy modules;
      implicit_submodules = Hashtbl.copy implicit_submodules;
      order = ClassHierarchy.Builder.copy order;
      aliases = Hashtbl.copy aliases;
      globals = Hashtbl.copy globals;
      dependencies = Dependencies.copy dependencies;
      undecorated_functions = Hashtbl.copy undecorated_functions
    }


  let statistics { class_definitions; globals; _ } =
    Format.asprintf
      "Found %d classes, and %d globals"
      (Hashtbl.length class_definitions)
      (Hashtbl.length globals)


  let pp format { order; aliases; globals; _ } =
    let aliases =
      let alias (key, data) = Format.asprintf "  %a -> %a" Identifier.pp key Type.pp_alias data in
      Hashtbl.to_alist aliases |> List.map ~f:alias |> String.concat ~sep:"\n"
    in
    let globals =
      let global (key, { Node.value; _ }) =
        Format.asprintf "  %a -> %a" Reference.pp key Annotation.pp value
      in
      Hashtbl.to_alist globals |> List.map ~f:global |> String.concat ~sep:"\n"
    in
    Format.fprintf
      format
      "Environment:\nOrder:\n%a\nAliases:\n%s\nGlobals:\n%s"
      ClassHierarchy.pp
      order
      aliases
      globals


  let show environment = Format.asprintf "%a" pp environment
end
