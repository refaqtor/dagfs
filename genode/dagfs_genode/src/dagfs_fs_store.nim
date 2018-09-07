#
# \brief  File-system backed Dagfs server
# \author Emery Hemingway
# \date   2017-11-04
#

#
# Copyright (C) 2017 - 2018 Genode Labs GmbH
#
# This file is part of the Genode OS framework, which is distributed
# under the terms of the GNU Affero General Public License version 3.
#

import std/streams, std/strutils, genode,
  dagfs, dagfs/stores, ./dagfs_client

componentConstructHook = proc (env: GenodeEnv) =
  let
    store = newFileStore("/") ## Storage backend for sessions
    backend = env.newDagfsBackend(store)
