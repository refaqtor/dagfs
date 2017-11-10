import asyncdispatch, ipld, ipfsdaemon, os, strutils, multiformats, streams, cbor, unixfs, ipldstore

when not declared(commandLineParams):
  {.error: "POSIX only utility".}

proc addCmd(store: IpldStore; params: seq[TaintedString]) =
  for path in params[1.. params.high]:
    let info = getFileInfo(path, followSymlink=false)
    case info.kind
    of pcFile:
      let (cid, size) = store.addFile path
      stdout.writeLine cid, " ", size, " ", path
    of pcDir:
      let cid = store.addDir path
      stdout.writeLine cid, " ", path
    else: continue

proc mergeCmd(store: IpldStore; params: seq[TaintedString]) =
  let
    root = newDag()

  for cidStr in params[1..params.high]:
    let cid = parseCid cidStr
    if cid.codec != MulticodecTag.Dag_cbor:
      stderr.writeLine cidStr, " is not CBOR encoded"
      quit QuitFailure
    let
      raw = waitFor store.getRaw(cid)
      subDag = parseDag raw
    root.merge subDag
  let cid = waitFor store.putDag(root)
  stdout.writeLine cid

proc infoCmd(store: IpldStore; params: seq[TaintedString]) {.async.} =
  for cidStr in params[1..params.high]:
    let
      cid = parseCid cidStr
    stdout.writeLine cid
    stdout.writeLine cid.toHex
    if cid.isDagCbor:
      let dag = await store.getDag(cid)
      stdout.writeLine dag

proc catCmd(store: IpldStore; params: seq[TaintedString]) {.async.} =
  for param in params[1..params.high]:
    let
      cid = parseCid param
      fut = newFutureStream[string]()
    asyncCheck store.fileStream(cid, fut)
    while true:
      let (valid, chunk) = await fut.read()
      if not valid: break
      stdout.write chunk

proc printUnixFs(node: UnixFsNode) =
  for name in node.walk:
    stdout.writeLine name

#[
proc lsCmd(store: IpldStore; params: seq[TaintedString]) {.async.} =
  for param in params[1..params.high]:
    echo param

    var root: UnixfsNode
    let
      cid = parseCid param
    echo cid
    let
      dag = await store.getDag(cid)
    echo dag
    root.fromCbor dag
    printUnixfs root
]#

proc main() =
  let params = commandLineParams()
  if params.len < 2:
    quit "insufficient parameters"

  let store = newFileStore "/tmp/ipld"

  case params[0]
  of "add":
    addCmd store, params
  of "merge":
    mergeCmd store, params
  of "info":
    waitFor infoCmd(store, params)
  of "cat":
    waitFor catCmd(store, params)
  of "ls":
    echo "fuck that shit"
    #waitFor lsCmd(store, params)

  close store
  quit()

main()
