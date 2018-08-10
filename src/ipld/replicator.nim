import streams, strutils, os, ../ipld, cbor, ./multiformats, ./store

type
  IpldReplicator* = ref IpldReplicatorObj
  IpldReplicatorObj* = object of IpldStoreObj
    toStore, fromStore: IpldStore
    cache: string
    cacheCid: Cid

proc replicatedPut(s: IpldStore; blk: string; hash: MulticodecTag): Cid =
  var r = IpldReplicator s
  r.toStore.put(blk, hash)

proc replicatedGetBuffer(s: IpldStore; cid: Cid; buf: pointer; len: Natural): int =
  var r = IpldReplicator s
  if r.cacheCid == cid:
    assert(cid.verify(r.cache), "cached block is invalid from previous get")
    if r.cache.len > len:
      raise newException(BufferTooSmall, "")
    result = r.cache.len
    copyMem(buf, r.cache[0].addr, result)
  else:
    try:
      result = r.toStore.getBuffer(cid, buf, len)
      r.cacheCid = cid
      r.cache.setLen result
      copyMem(r.cache[0].addr, buf, result)
      assert(cid.verify(r.cache), "cached block is invalid after copy from To store")
    except MissingObject:
      result = r.fromStore.getBuffer(cid, buf, len)
      r.cacheCid = cid
      r.cache.setLen result
      copyMem(r.cache[0].addr, buf, result)
      assert(cid.verify(r.cache), "replicate cache is invalid after copy from From store")
      discard r.toStore.put(r.cache, cid.hash)

proc replicatedGet(s: IpldStore; cid: Cid; result: var string) =
  var r = IpldReplicator s
  try: r.toStore.get(cid, result)
  except MissingObject:
    r.fromStore.get(cid, result)
    discard r.toStore.put(result, cid.hash)

proc newIpldReplicator*(toStore, fromStore: IpldStore): IpldReplicator =
  ## Blocks retrieved by `get` are not verified.
  IpldReplicator(
    putImpl: replicatedPut,
    getBufferImpl: replicatedGetBuffer,
    getImpl: replicatedGet,
    toStore: toStore,
    fromStore: fromStore,
    cache: "",
    cacheCid: initCid())
