(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2

let test_compute_hashes_to_keys _ =
  let open Analysis.EnvironmentSharedMemory in
  assert_equal
    ~cmp:(String.Map.equal String.equal)
    (String.Map.of_alist_exn
       [ OrderEdges.hash_of_key 15, OrderEdges.serialize_key 15;
         OrderBackedges.hash_of_key 15, OrderBackedges.serialize_key 15;
         OrderAnnotations.hash_of_key 15, OrderAnnotations.serialize_key 15 ])
    (Service.TypeOrder.compute_hashes_to_keys ~indices:[15] ~annotations:[]);
  assert_equal
    ~cmp:(String.Map.equal String.equal)
    (String.Map.of_alist_exn
       [OrderIndices.hash_of_key "fifteen", OrderIndices.serialize_key "fifteen"])
    (Service.TypeOrder.compute_hashes_to_keys ~indices:[] ~annotations:["fifteen"])


let () = "typeOrder" >::: ["compute_hashes_to_keys" >:: test_compute_hashes_to_keys] |> Test.run
