#
# \brief  Scenefs replicator server
# \author Emery Hemingway
#

#
# Copyright (C) 2017-2018 Genode Labs GmbH
#
# This file is part of the Genode OS framework, which is distributed
# under the terms of the GNU Affero General Public License version 3.
#

import genode, genode/servers, genode/roms,
  scenefs/replicator, scenefs/genode/ipldclient, scenefs/genode/ipldserver

componentConstructHook = proc (env: GenodeEnv) =
  let
    src = env.newIpldClient("from")
    dst = env.newIpldClient("to")
    replicator = newIpldReplicator(dst, src)
    server = env.newIpldServer(replicator)
      # Store server

  proc processSessions(rom: RomClient) =
    ## ROM signal handling procedure
    ## Create and close 'Ipld' sessions from the
    ## 'sessions_requests' ROM.
    update rom
    var requests = initSessionRequestsParser(rom)
    for id in requests.close:
      server.close id
    for id, service, label in requests.create:
      if service == "Ipld":
        server.create id, label, requests.args

  let sessionsHandle = env.newRomHandler(
    "session_requests", processSessions)

  env.announce "Ipld"
  process sessionsHandle
    # Process request backlog and return to the entrypoint.
