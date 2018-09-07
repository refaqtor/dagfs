when not defined(genode):
  {.error: "Genode only module".}

import std/asyncdispatch
import dagfs/stores, dagfs/tcp

when not defined(genode):
  {.error: "Genode only server".}

componentConstructHook = proc (env: GenodeEnv) =
  echo "--- Dagfs TCP server ---"
  let
    store = newFileStore "/"
    server = newTcpServer store
  waitFor server.serve()
