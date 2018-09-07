#
# \brief  Server-side IPLD session interface
# \author Emery Hemingway
# \date   2017-11-04
#

#
# Copyright (C) 2017 Genode Labs GmbH
#
# This file is part of the Genode OS framework, which is distributed
# under the terms of the GNU Affero General Public License version 3.
#

import xmltree, strtabs, xmlparser, streams, tables,
  genode, genode/servers, genode/roms, ipld/genode/ipldserver, ipld/ipfsdaemon
  
proc newDaemonStore(env: GenodeEnv): IpfsStore =
  ## Open a connection to an IPFS daemon.
  try:
    let
      configRom = env.newRomClient("config")
      config = configRom.xml
    close configRom
    let daemonUrl = config.attrs["ipfs_url"]
    result = newIpfsStore(daemonUrl)
  except:
    let err = getCurrentException()
    quit("failed to connect IPFS, " & err.msg)

componentConstructHook = proc (env: GenodeEnv) =
  let
    store = env.newDaemonStore()
      # Server backend
    server = env.newIpldServer(store)
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
