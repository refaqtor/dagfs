when not defined(genode):
  {.error: "Genode only Dagfs client".}

import cbor, std/tables, std/strutils

import genode, genode/signals

import dagfs, dagfs/stores, ./dagfs_session

const
  currentPath = currentSourcePath.rsplit("/", 1)[0]
  dagfsClientH = currentPath & "/dagfs_client.h"
{.passC: "-I" & currentPath & "/../../include".}

type
  DagfsClientBase {.importcpp, header: dagfsClientH.} = object
  DagfsClientCpp = Constructible[DagfsClientBase]

proc construct(cpp: DagfsClientCpp; env: GenodeEnv; label: cstring; txBufSize: int) {.
  importcpp.}

proc bulk_buffer_size(cpp: DagfsClientCpp): csize {.
  importcpp: "#->conn.source().bulk_buffer_size()".}

proc sigh_ack_avail(cpp: DagfsClientCpp; sig: SignalContextCapability) {.
  importcpp: "#->conn.channel().sigh_ack_avail(@)".}

proc ready_to_submit(cpp: DagfsClientCpp): bool {.
  importcpp: "#->conn.source().ready_to_submit()".}

proc ready_to_ack(cpp: DagfsClientCpp): bool {.
  importcpp: "#->conn.source().ready_to_ack()".}

proc ack_avail(cpp: DagfsClientCpp): bool {.
  importcpp: "#->conn.source().ack_avail()".}

proc alloc_packet(cpp: DagfsClientCpp; size = MaxPacketSize): DagfsPacket {.
  importcpp: "#->conn.source().alloc_packet(@)".}

proc packet_content(cpp: DagfsClientCpp; pkt: DagfsPacket): pointer {.
  importcpp: "#->conn.source().packet_content(@)".}

proc submit_packet(cpp: DagfsClientCpp; pkt: DagfsPacket) {.
  importcpp: "#->conn.source().submit_packet(@)".}

proc submit_packet(cpp: DagfsClientCpp; pkt: DagfsPacket; cid: cstring; op: DagfsOpcode) {.
  importcpp: "#->conn.source().submit_packet(Dagfs::Packet(#, (char const *)#, #))".}

proc get_acked_packet(cpp: DagfsClientCpp): DagfsPacket {.
  importcpp: "#->conn.source().get_acked_packet()".}

proc release_packet(cpp: DagfsClientCpp; pkt: DagfsPacket) {.
  importcpp: "#->conn.source().release_packet(@)".}

type
  DagfsFrontend* = ref DagfsFrontendObj
  DagfsFrontendObj = object of DagfsStoreObj
    ## Dagfs session client consuming a store.
    cpp: DagfsClientCpp

proc fendClose(s: DagfsStore) =
  var fend = DagfsFrontend(s)
  destruct fend.cpp

proc fendPutBuffer(s: DagfsStore; buf: pointer; len: Natural): Cid =
  ## Put block to Dagfs server, blocks for two packet round-trip.
  var fend = DagfsFrontend(s)
  var
    pktCid = dagHash(buf, len)
  if pktCid == zeroChunk:
    return pktCid
  assert(fend.cpp.readyToSubmit, "Dagfs client packet queue congested")
  var pkt = fend.cpp.allocPacket(len)
  let pktBuf = fend.cpp.packetContent pkt
  defer: fend.cpp.releasePacket pkt
  assert(not pktBuf.isNil, "allocated packet has nil content")
  assert(len <= pkt.size)
  pkt.setLen len
  copyMem(pktBuf, buf, len)
  assert(fend.cpp.readyToSubmit, "Dagfs client packet queue congested")
  fend.cpp.submitPacket(pkt, pktCid.toHex, PUT)
  let ack = fend.cpp.getAckedPacket()
  doAssert(ack.error == OK)
  result = ack.cid()
  assert(result.isValid, "server returned a packet with and invalid CID")

proc fendPut(s: DagfsStore; blk: string): Cid =
  ## Put block to Dagfs server, blocks for two packet round-trip.
  let fend = DagfsFrontend(s)
  var
    blk = blk
    pktCid = dagHash blk
  if pktCid == zeroChunk:
    return pktCid
  assert(fend.cpp.readyToSubmit, "Dagfs client packet queue congested")
  var pkt = fend.cpp.allocPacket(blk.len)
  let pktBuf = fend.cpp.packetContent pkt
  defer: fend.cpp.releasePacket pkt
  assert(not pktBuf.isNil, "allocated packet has nil content")
  assert(blk.len <= pkt.size)
  pkt.setLen blk.len
  copyMem(pktBuf, blk[0].addr, blk.len)
  assert(fend.cpp.readyToSubmit, "Dagfs client packet queue congested")
  fend.cpp.submitPacket(pkt, pktCid.toHex, PUT)
  let ack = fend.cpp.getAckedPacket()
  doAssert(ack.error == OK)
  result = ack.cid()
  assert(result.isValid, "server returned a packet with and invalid CID")

proc fendGetBuffer(s: DagfsStore; cid: Cid; buf: pointer; len: Natural): int =
  ## Get from Dagfs server, blocks for packet round-trip.
  let fend = DagfsFrontend(s)
  assert(fend.cpp.readyToSubmit, "Dagfs client packet queue congested")
  let pkt = fend.cpp.allocPacket len
  fend.cpp.submitPacket(pkt, cid.toHex, GET)
  let ack = fend.cpp.getAckedPacket
  doAssert(ack.cid == cid)
  if ack.error == OK:
    let pktBuf = fend.cpp.packetContent ack
    assert(not pktBuf.isNil, "ack packet has nil content")
    assert(ack.len <= len)
    assert(ack.len > 0)
    result = ack.len
    copyMem(buf, pktBuf, result)
  if pkt.size > 0:
    fend.cpp.releasePacket pkt
      # free the original packet that was allocated
  case ack.error:
  of OK: discard
  of MISSING:
    raiseMissing cid
  else:
    raise newException(CatchableError, "Dagfs packet error " & $ack.error)

proc fendGet(s: DagfsStore; cid: Cid; result: var string) =
  ## Get from Dagfs server, blocks for packet round-trip.
  let fend = DagfsFrontend(s)
  assert(fend.cpp.readyToSubmit, "Dagfs client packet queue congested")
  let pkt = fend.cpp.allocPacket()
  defer: fend.cpp.releasePacket pkt
  fend.cpp.submitPacket(pkt, cid.toHex, GET)
  let ack = fend.cpp.getAckedPacket()
  doAssert(ack.cid == cid)
  case ack.error:
  of OK:
    let ackBuf = fend.cpp.packetContent ack
    assert(not ackBuf.isNil)
    assert(0 < ack.len, "server return zero length packet")
    result.setLen ack.len
    copyMem(result[0].addr, ackBuf, result.len)
    assert(cid.verify(result), "Dagfs client packet failed verification")
  of MISSING:
    raiseMissing cid
  else:
    raise newException(CatchableError, "Dagfs packet error " & $ack.error)

const
  defaultBufferSize* = maxChunkSize * 4

proc newDagfsFrontend*(env: GenodeEnv; label = ""; bufferSize = defaultBufferSize): DagfsFrontend =
  ## Open a new frontend client connection.
  ## Blocks retrieved by `get` are not verified.
  new result
  construct(result.cpp, env, label, bufferSize)
  result.closeImpl = fendClose
  result.putBufferImpl = fendPutBuffer
  result.putImpl = fendPut
  result.getBufferImpl = fendGetBuffer
  result.getImpl = fendGet

type
  DagfsBackend* = ref DagfsBackendObj
  DagfsBackendObj = object
    ## Dagfs session client providing a store.
    cpp: DagfsClientCpp
    store: DagfsStore
    sigh: SignalHandler

const zeroHex = zeroChunk.toHex

proc newDagfsBackend*(env: GenodeEnv; store: DagfsStore; label = ""; bufferSize = defaultBufferSize): DagfsBackend =
  ## Open a new backend client connection.
  doAssert(bufferSize > maxChunkSize, "Dagfs backend session buffer is too small")
  let bend = DagfsBackend(store: store)
  construct(bend.cpp, env, label, bufferSize)
  bend.sigh = env.ep.newSignalHandler do ():
    while bend.cpp.ackAvail:
      var pkt = bend.cpp.getAckedPacket()
      let
        buf = bend.cpp.packetContent(pkt)
        cid = pkt.cid
      case pkt.operation
      of GET:
        try:
          let n = store.getBuffer(cid, buf, pkt.size)
          pkt.setLen(n)
          bend.cpp.submitPacket(pkt, cid.toHex, PUT)
        except MissingChunk:
          pkt.setError(MISSING)
          bend.cpp.submitPacket(pkt)
      of PUT:
        let putCid = store.putBuffer(buf, pkt.len)
        doAssert(putCid == cid, $putCid & " PUT CID mismatch with server")
        bend.cpp.submitPacket(pkt, putCid.toHex, Idle)
      else:
        echo "unhandled packet from server"
        bend.cpp.submitPacket(pkt, zeroHex, Idle)

  bend.cpp.sighAckAvail(bend.sigh.cap)
  for _ in 1..(bend.cpp.bulkBufferSize div maxChunkSize):
    let pkt = bend.cpp.allocPacket(maxChunkSize)
    assert(bend.cpp.readyToSubmit)
    bend.cpp.submitPacket(pkt, zeroHex, IDLE)
  bend
