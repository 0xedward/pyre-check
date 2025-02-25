/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#include "hh_assert.h"

#define CAML_NAME_SPACE
#include <caml/callback.h>
#include <caml/fail.h>

void raise_assertion_failure(char* msg) {
  caml_raise_with_string(*caml_named_value("c_assertion_failure"), msg);
}
