import streams, os, parseopt

import ipfsdaemon, ipldstore, ipld, unixfs

proc readFile(store: IpldStore; s: Stream; cid: Cid) =
  var chunk = ""
  let file = store.open(cid)
  assert(not file.isNil)
  assert(file.isFile)
  if file.cid.isRaw:
    store.get(file.cid, chunk)
    s.write chunk
  else:
    var n = 0
    for i in 0..file.links.high:
      store.get(file.links[i].cid, chunk)
      doAssert(n+chunk.len <= file.size)
      s.write chunk
      n.inc chunk.len
    doAssert(n == file.size)

let
  store = newIpfsStore("http://127.0.0.1:5001")
  stream = stdout.newFileStream

for kind, key, value in getopt():
  if kind == cmdArgument:
    let cid = key.parseCid
    if cid.isRaw:
      let chunk = store.get(cid)
      stream.write chunk
    else:
      readFile(store, stream, cid)
