when not defined(genode):
  {.error: "Genode only module".}

import std/asyncdispatch
import ./dagfs_client, dagfs/tcp

when not defined(genode):
  {.error: "Genode only server".}

componentConstructHook = proc (env: GenodeEnv) =
  echo "--- Dagfs TCP server ---"
  let
    store = env.newDagfsFrontend()
    server = newTcpServer store
  waitFor server.serve()
  quit "--- Dagfs TCP server died ---"
