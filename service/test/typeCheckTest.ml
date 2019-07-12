(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2
open Pyre
open Test

let assert_errors ?filter_directories ?ignore_all_errors ?search_path ~root ~files errors =
  let configuration =
    Configuration.Analysis.create
      ?filter_directories
      ?ignore_all_errors
      ?search_path
      ~project_root:root
      ~local_root:root
      ()
  in
  let scheduler = Scheduler.mock () in
  List.iter ~f:File.write files;
  let module_tracker = Service.ModuleTracker.create configuration in
  let files =
    Service.ModuleTracker.source_paths module_tracker
    |> List.map ~f:(fun { Ast.SourcePath.relative_path; _ } ->
           Path.Relative relative_path |> File.create)
  in
  let { Service.Parser.parsed = handles; _ } =
    Service.Parser.parse_sources ~configuration ~scheduler ~preprocessing_state:None ~files
  in
  let ((module Handler : Analysis.Environment.Handler) as environment) =
    (module Service.Environment.SharedHandler : Analysis.Environment.Handler)
  in
  Test.populate_shared_memory ~configuration ~sources:handles;
  Test.populate ~configuration environment (typeshed_stubs ~include_helper_builtins:false ());
  let actual_errors =
    Service.Check.analyze_sources ~scheduler ~configuration ~environment ~handles ()
    |> List.map ~f:(Analysis.Error.description ~show_error_traces:false)
  in
  List.map handles ~f:(fun handle -> Ast.Source.qualifier ~handle) |> Handler.purge;
  assert_equal
    ~printer:(List.to_string ~f:ident)
    ~cmp:(List.equal ~equal:String.equal)
    errors
    actual_errors


let type_check_sources_list_test context =
  let create_files ~root content =
    let default_content =
      {|
        class object():
          def __sizeof__(self) -> int: pass
        class typing.Sized: ...
        class float():
          pass
        class int(float):
          pass
        class str(typing.Sized):
          pass
      |}
      |> trim_extra_indentation
    in
    [ File.create
        ~content:(default_content ^ "\n" ^ (content |> trim_extra_indentation))
        (Path.create_relative ~root ~relative:"test.py") ]
  in
  let check _ =
    let root = Path.current_working_directory () in
    let files = {|
        def foo() -> str:
          return 1
      |} |> create_files ~root in
    assert_errors ~root ~files ["Incompatible return type [7]: Expected `str` but got `int`."]
  in
  with_bracket_chdir context (bracket_tmpdir context) check


let test_filter_directories context =
  let root = Path.create_absolute (bracket_tmpdir context) in
  let check_path = Path.create_relative ~root ~relative:"check/a.py" in
  let ignore_path = Path.create_relative ~root ~relative:"ignore/b.py" in
  let content =
    {|
      class C:
        pass
      class D:
        def __init__(self):
          pass
      def foo() -> C:
        return D()
    |}
    |> Test.trim_extra_indentation
  in
  let files = [File.create ~content check_path; File.create ~content ignore_path] in
  assert_errors
    ~root
    ~files
    [ "Incompatible return type [7]: Expected `C` but got `D`.";
      "Incompatible return type [7]: Expected `C` but got `D`." ];

  assert_errors
    ~root
    ~filter_directories:[Path.create_relative ~root ~relative:"check"]
    ~ignore_all_errors:[Path.create_relative ~root ~relative:"check/search"]
    ~files
    ["Incompatible return type [7]: Expected `C` but got `D`."];

  (* The structure:
   *  /root/check <- pyre is meant to analyze here
   *  /root/check/search <- this is added to the search path, handles are relative to here instead
   *                       of check. The practical case here is resource_cache/typeshed. *)
  let root = Path.create_absolute (bracket_tmpdir context) in
  assert_errors
    ~root
    ~search_path:[SearchPath.Root (Path.create_relative ~root ~relative:"check/search")]
    ~filter_directories:[Path.create_relative ~root ~relative:"check"]
    ~ignore_all_errors:[Path.create_relative ~root ~relative:"check/search"]
    ~files:
      [ File.create ~content (Path.create_relative ~root ~relative:"check/file.py");
        File.create ~content (Path.create_relative ~root ~relative:"check/search/file.py") ]
    ["Incompatible return type [7]: Expected `C` but got `D`."];
  let root = Path.create_absolute (bracket_tmpdir context) in
  assert_errors
    ~root
    ~filter_directories:[Path.create_relative ~root ~relative:"check"]
    ~ignore_all_errors:[Path.create_relative ~root ~relative:"check/ignore"]
    ~files:[File.create ~content (Path.create_relative ~root ~relative:"check/ignore/file.py")]
    []


let () =
  "typeChecker"
  >::: [ "type_check_sources_list" >:: type_check_sources_list_test;
         "filter_directories" >:: test_filter_directories ]
  |> Test.run
