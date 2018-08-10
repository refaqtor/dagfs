#
# \brief  IPLD server factory
# \author Emery Hemingway
# \date   2017-11-11
#

#
# Copyright (C) 2017 Genode Labs GmbH
#
# This file is part of the Genode OS framework, which is distributed
# under the terms of the GNU Affero General Public License version 3.
#

import std/strtabs, std/tables, std/xmltree, std/strutils

import cbor, genode, genode/signals, genode/servers, ipld, ipld/store, ipldsession

const
  currentPath = currentSourcePath.rsplit("/", 1)[0]
  ipldserverH = currentPath & "/ipldserver.h"

type
  IpldSessionComponentBase {.importcpp, header: ipldserverH.} = object
  SessionCpp = Constructible[IpldSessionComponentBase]
  Session = ref object
    cpp: SessionCpp
    sig: SignalHandler
    store: IpldStore
    id: SessionId
    label: string

proc processPacket(session: Session; pkt: var IpldPacket) =
  proc packetContent(cpp: SessionCpp; pkt: IpldPacket): pointer {.
    importcpp: "#->sink().packet_content(@)".}
  let cid = pkt.cid
  case pkt.operation
  of PUT:
    try:
      var
        pktBuf = session.cpp.packetContent pkt
        heapBuf = newString pkt.len
      copyMem(heapBuf[0].addr, pktBuf, heapBuf.len)
      let putCid = session.store.put(heapBuf, cid.hash)
      assert(putCid.isValid, "server packet returned invalid CID from put")
      pkt.setCid putCid
    except:
      echo "unhandled PUT error ", getCurrentExceptionMsg()
      pkt.setError ERROR
  of GET:
    try:
      let
        pktBuf = session.cpp.packetContent pkt
        n = session.store.getBuffer(cid, pktBuf, pkt.size)
      pkt.setLen n
    except BufferTooSmall:
      pkt.setError OVERSIZE
    except MissingObject:
      pkt.setError MISSING
    except:
      echo "unhandled GET error ", getCurrentExceptionMsg()
      pkt.setError ERROR
  else:
    echo "invalid packet operation"
    pkt.setError ERROR

proc newSession(env: GenodeEnv; store: IpldStore; id: SessionId; label, args: string): Session =
  ## Create a new session and packet handling procedure
  let session = new Session
  assert(not session.isNil)
  proc construct(cpp: SessionCpp; env: GenodeEnv; args: cstring) {.importcpp.}
  session.cpp.construct(env, args)
  session.store = store
  session.id = id
  session.label = label
  session.sig = env.ep.newSignalHandler do ():
    proc packetAvail(cpp: SessionCpp): bool {.
      importcpp: "#->sink().packet_avail()".}
    proc readyToAck(cpp: SessionCpp): bool {.
      importcpp: "#->sink().ready_to_ack()".}
    while session.cpp.packetAvail and session.cpp.readyToAck:
      proc getPacket(cpp: SessionCpp): IpldPacket {.
        importcpp: "#->sink().get_packet()".}
      var pkt = session.cpp.getPacket()
      session.processPacket pkt
      proc acknowledgePacket(cpp: SessionCpp; pkt: IpldPacket) {.
        importcpp: "#->sink().acknowledge_packet(@)".}
      session.cpp.acknowledgePacket(pkt)

  proc packetHandler(cpp: SessionCpp; cap: SignalContextCapability) {.
    importcpp: "#->packetHandler(@)".}
  session.cpp.packetHandler(session.sig.cap)
  result = session

proc manage(ep: Entrypoint; s: Session): IpldSessionCapability =
  ## Manage a session from the default entrypoint.
  proc manage(ep: Entrypoint; cpp: SessionCpp): IpldSessionCapability {.
    importcpp: "#.manage(*#)".}
  result = ep.manage(s.cpp)
  GC_ref s

proc dissolve(ep: Entrypoint; s: Session) =
  ## Dissolve a session from the entrypoint so that it can be freed.
  proc dissolve(ep: Entrypoint; cpp: SessionCpp) {.
    importcpp: "#.dissolve(*#)".}
  ep.dissolve(s.cpp)
  destruct(s.cpp)
  dissolve(s.sig)
  GC_unref s

type
  IpldServer* = ref object
    env: GenodeEnv
    store*: IpldStore
    sessions*: Table[SessionId, Session]

proc newIpldServer*(env: GenodeEnv; store: IpldStore): IpldServer =
  IpldServer(
    env: env, store: store,
    sessions: initTable[SessionId, Session]())

proc create*(server: IpldServer; id: SessionId; label, args: string) =
  if not server.sessions.contains id:
    try:
      let
        session = newSession(server.env, server.store, id, label, args)
        cap = server.env.ep.manage(session)
      server.sessions[id] = session
      proc deliverSession(env: GenodeEnv; id: SessionId; cap: IpldSessionCapability) {.
        importcpp: "#->parent().deliver_session_cap(Genode::Parent::Server::Id{#}, #)".}
      server.env.deliverSession(id, cap)
      echo "session opened for ", label
    except:
      echo "failed to create session for '", label, "', ", getCurrentExceptionMsg()
      server.env.sessionResponseDeny id

proc close*(server: IpldServer; id: SessionId) =
  ## Close a session at the IPLD server.
  if server.sessions.contains id:
    let session = server.sessions[id]
    server.env.ep.dissolve(session)
    server.sessions.del id
    server.env.sessionResponseClose id
