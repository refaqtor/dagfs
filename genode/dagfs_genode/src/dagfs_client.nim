when not defined(genode):
  {.error: "Genode only Dagfs client".}

import cbor, genode, std/tables, std/strutils

import dagfs, dagfs/stores, dagfs/genode/dagfs_session

const
  currentPath = currentSourcePath.rsplit("/", 1)[0]
  dagfsClientH = currentPath & "/dagfs_client.h"
{.passC: "-I" & currentPath & "/../../../genode/include".}

type
  DagfsClientBase {.importcpp, header: dagfsClientH.} = object
  DagfsClientCpp = Constructible[DagfsClientBase]

proc sigh_ack_avail(cpp: DagfsClientCpp; sig: SignalContextCapability) {.
  importcpp: "#->conn.channel().sigh_ack_avail(@)", tags: [RpcEffect].}

proc readyToSubmit(cpp: DagfsClientCpp): bool {.
  importcpp: "#->conn.source().ready_to_submit()".}

proc readyToAck(cpp: DagfsClientCpp): bool {.
  importcpp: "#->conn.source().ready_to_ack()".}

proc ackAvail(cpp: DagfsClientCpp): bool {.
  importcpp: "#->conn.source().ack_avail()".}

proc allocPacket(cpp: DagfsClientCpp; size = MaxPacketSize): DagfsPacket {.
  importcpp: "#->conn.source().alloc_packet(@)".}

proc packetContent(cpp: DagfsClientCpp; pkt: DagfsPacket): pointer {.
  importcpp: "#->conn.source().packet_content(@)".}

proc submitPacket(cpp: DagfsClientCpp; pkt: DagfsPacket; cid: cstring; op: DagfsOpcode) {.
  importcpp: "#->conn.source().submit_packet(Dagfs::Packet(#, (char const *)#, #))".}

proc getAckedPacket(cpp: DagfsClientCpp): DagfsPacket {.
  importcpp: "#->conn.source().get_acked_packet()".}

proc releasePacket(cpp: DagfsClientCpp; pkt: DagfsPacket) {.
  importcpp: "#->conn.source().release_packet(@)".}

type
  DagfsClient* = ref DagfsClientObj
  DagfsClientObj = object of DagfsStoreObj
    ## IPLD session client
    cpp: DagfsClientCpp

proc icClose(s: DagfsStore) =
  var ic = DagfsClient(s)
  destruct ic.cpp

proc icPut(s: DagfsStore; blk: string): Cid =
  ## Put block to Dagfs server, blocks for two packet round-trip.
  let ic = DagfsClient(s)
  var
    blk = blk
    pktCid = dagHash blk
  if pktCid == zeroBlock:
    return pktCid
  assert(ic.cpp.readyToSubmit, "Dagfs client packet queue congested")
  var pkt = ic.cpp.allocPacket(blk.len)
  let pktBuf = ic.cpp.packetContent pkt
  defer: ic.cpp.releasePacket pkt
  assert(not pktBuf.isNil, "allocated packet has nil content")
  assert(pkt.size >= blk.len)
  pkt.setLen blk.len
  copyMem(pktBuf, blk[0].addr, blk.len)
  assert(ic.cpp.readyToSubmit, "Dagfs client packet queue congested")
  ic.cpp.submitPacket(pkt, pktCid.toHex, PUT)
  let ack = ic.cpp.getAckedPacket()
  doAssert(ack.error == OK)
  result = ack.cid()
  assert(result.isValid, "server returned a packet with and invalid CID")

proc icGetBuffer(s: DagfsStore; cid: Cid; buf: pointer; len: Natural): int =
  ## Get from Dagfs server, blocks for packet round-trip.
  let ic = DagfsClient(s)
  assert(ic.cpp.readyToSubmit, "Dagfs client packet queue congested")
  let pkt = ic.cpp.allocPacket len
  ic.cpp.submitPacket(pkt, cid.toHex, GET)
  let ack = ic.cpp.getAckedPacket
  doAssert(ack.cid == cid)
  if ack.error == OK:
    let pktBuf = ic.cpp.packetContent ack
    assert(not pktBuf.isNil, "ack packet has nil content")
    assert(ack.len <= len)
    assert(ack.len > 0)
    result = ack.len
    copyMem(buf, pktBuf, result)
  if pkt.size > 0:
    ic.cpp.releasePacket pkt
      # free the original packet that was allocated
  case ack.error:
  of OK: discard
  of MISSING:
    raise cid.newMissingObject
  else:
    raise newException(CatchableError, "Dagfs packet error " & $ack.error)

proc icGet(s: DagfsStore; cid: Cid; result: var string) =
  ## Get from Dagfs server, blocks for packet round-trip.
  let ic = DagfsClient(s)
  assert(ic.cpp.readyToSubmit, "Dagfs client packet queue congested")
  let pkt = ic.cpp.allocPacket()
  defer: ic.cpp.releasePacket pkt
  ic.cpp.submitPacket(pkt, cid.toHex, GET)
  let ack = ic.cpp.getAckedPacket()
  doAssert(ack.cid == cid)
  case ack.error:
  of OK:
    let ackBuf = ic.cpp.packetContent ack
    assert(not ackBuf.isNil)
    assert(ack.len > 0)
    result.setLen ack.len
    copyMem(result[0].addr, ackBuf, result.len)
    assert(cid.verify(result), "Dagfs client packet failed verification")
  of MISSING:
    raise cid.newMissingObject
  else:
    raise newException(CatchableError, "Dagfs packet error " & $ack.error)

const
  DefaultDagfsBufferSize* = 1 shl 20

proc newDagfsClient*(env: GenodeEnv; label = ""; bufferSize = DefaultDagfsBufferSize): DagfsClient =
  ## Blocks retrieved by `get` are not verified.
  proc construct(cpp: DagfsClientCpp; env: GenodeEnv; label: cstring; txBufSize: int) {.
    importcpp.}
  new result
  construct(result.cpp, env, label, bufferSize)
  result.closeImpl = icClose
  result.putImpl = icPut
  result.getBufferImpl = icGetBuffer
  result.getImpl = icGet
