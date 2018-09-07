#
# \brief  File-system backed Dagfs server
# \author Emery Hemingway
# \date   2017-11-04
#

#
# Copyright (C) 2017 Genode Labs GmbH
#
# This file is part of the Genode OS framework, which is distributed
# under the terms of the GNU Affero General Public License version 3.
#

import std/streams, std/strutils,
  genode, genode/servers, genode/roms, genode/parents,
  dagfs, dagfs/stores, ./dagfs_server

componentConstructHook = proc (env: GenodeEnv) =
  let
    store = newFileStore("/") ## Storage backend for sessions
    server = env.newDagfsServer(store) ## Server to the store

  proc processSessions(sessionsRom: RomClient) =
    ## ROM signal handling procedure
    ## Create and close 'Dagfs' sessions from the
    ## 'sessions_requests' ROM.
    update sessionsRom
    let rs = sessionsRom.newStream
    var requests = initSessionRequestsParser sessionsRom
    for id in requests.close:
      server.close id
    for id, label, args in requests.create "dagfs":
      server.create id, label, args
    close rs

  let sessionsHandler = env.newRomHandler("session_requests", processSessions)
    ## Session requests routed to us from the parent

  env.parent.announce("dagfs") # Announce service to parent.
  process sessionsHandler # Process the initial request backlog.
