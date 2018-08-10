#
# \brief  IpldStore interface to the IPLD session
# \author Emery Hemingway
# \date   2017-11-04
#

#
# Copyright (C) 2017 Genode Labs GmbH
#
# This file is part of the Genode OS framework, which is distributed
# under the terms of the GNU Affero General Public License version 3.
#

when not defined(genode):
  {.error: "Genode only IPLD client".}

import cbor, genode, tables, strutils

import ipld, ipld/multiformats, ipld/store, ipld/genode/ipldsession

const
  currentPath = currentSourcePath.rsplit("/", 1)[0]
  ipldClientH = currentPath & "/ipldclient.h"
{.passC: "-I" & currentPath.}

type
  IpldClientBase {.importcpp, header: ipldClientH.} = object
  IpldClientCpp = Constructible[IpldClientBase]

proc sigh_ack_avail(cpp: IpldClientCpp; sig: SignalContextCapability) {.
  importcpp: "#->conn.channel().sigh_ack_avail(@)", tags: [RpcEffect].}

proc readyToSubmit(cpp: IpldClientCpp): bool {.
  importcpp: "#->conn.source().ready_to_submit()".}

proc readyToAck(cpp: IpldClientCpp): bool {.
  importcpp: "#->conn.source().ready_to_ack()".}

proc ackAvail(cpp: IpldClientCpp): bool {.
  importcpp: "#->conn.source().ack_avail()".}

proc allocPacket(cpp: IpldClientCpp; size = MaxPacketSize): IpldPacket {.
  importcpp: "#->conn.source().alloc_packet(@)".}

proc packetContent(cpp: IpldClientCpp; pkt: IpldPacket): pointer {.
  importcpp: "#->conn.source().packet_content(@)".}

proc submitPacket(cpp: IpldClientCpp; pkt: IpldPacket; cid: cstring; op: IpldOpcode) {.
  importcpp: "#->conn.source().submit_packet(Ipld::Packet(#, (char const *)#, #))".}

proc getAckedPacket(cpp: IpldClientCpp): IpldPacket {.
  importcpp: "#->conn.source().get_acked_packet()".}

proc releasePacket(cpp: IpldClientCpp; pkt: IpldPacket) {.
  importcpp: "#->conn.source().release_packet(@)".}

type
  IpldClient* = ref IpldClientObj
  IpldClientObj = object of IpldStoreObj
    ## IPLD session client
    cpp: IpldClientCpp

proc icClose(s: IpldStore) =
  var ic = IpldClient(s)
  destruct ic.cpp

proc icPut(s: IpldStore; blk: string; hash: MulticodecTag): Cid =
  ## Put block to Ipld server, blocks for two packet round-trip.
  let ic = IpldClient(s)
  var blk = blk
  var pktCid = initCid()
  pktCid.hash = hash
  assert(ic.cpp.readyToSubmit, "Ipld client packet queue congested")
  var pkt = ic.cpp.allocPacket(blk.len)
  let pktBuf = ic.cpp.packetContent pkt
  defer: ic.cpp.releasePacket pkt
  assert(not pktBuf.isNil, "allocated packet has nil content")
  assert(pkt.size >= blk.len)
  pkt.setLen blk.len
  copyMem(pktBuf, blk[0].addr, blk.len)
  assert(ic.cpp.readyToSubmit, "Ipld client packet queue congested")
  ic.cpp.submitPacket(pkt, pktCid.toHex, PUT)
  let ack = ic.cpp.getAckedPacket()
  doAssert(ack.error == OK)
  result = ack.cid()
  assert(result.isValid, "server returned a packet with and invalid CID")

proc icGetBuffer(s: IpldStore; cid: Cid; buf: pointer; len: Natural): int =
  ## Get from Ipld server, blocks for packet round-trip.
  let ic = IpldClient(s)
  assert(ic.cpp.readyToSubmit, "Ipld client packet queue congested")
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
    raise newException(SystemError, "Ipld packet error " & $ack.error)

proc icGet(s: IpldStore; cid: Cid; result: var string) =
  ## Get from Ipld server, blocks for packet round-trip.
  let ic = IpldClient(s)
  assert(ic.cpp.readyToSubmit, "Ipld client packet queue congested")
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
    assert(cid.verify(result), "Ipld client packet failed verification")
  of MISSING:
    raise cid.newMissingObject
  else:
    raise newException(SystemError, "Ipld packet error " & $ack.error)

const
  DefaultIpldBufferSize* = 1 shl 20

proc newIpldClient*(env: GenodeEnv; label = ""; bufferSize = DefaultIpldBufferSize): IpldClient =
  ## Blocks retrieved by `get` are not verified.
  proc construct(cpp: IpldClientCpp; env: GenodeEnv; label: cstring; txBufSize: int) {.
    importcpp.}
  new result
  construct(result.cpp, env, label, bufferSize)
  result.closeImpl = icClose
  result.putImpl = icPut
  result.getBufferImpl = icGetBuffer
  result.getImpl = icGet
