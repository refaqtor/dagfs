#
# \brief  Dagfs server factory
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

import cbor, genode, genode/signals, genode/servers, genode/parents,
  dagfs, dagfs/stores, ./dagfs_session

const
  currentPath = currentSourcePath.rsplit("/", 1)[0]
  dagfsserverH = currentPath & "/dagfs_server.h"

type
  DagfsSessionComponentBase {.importcpp, header: dagfsserverH.} = object
  SessionCpp = Constructible[DagfsSessionComponentBase]
  Session = ref object
    cpp: SessionCpp
    sig: SignalHandler
    store: DagfsStore
    id: ServerId
    label: string

proc processPacket(session: Session; pkt: var DagfsPacket) =
  proc packetContent(cpp: SessionCpp; pkt: DagfsPacket): pointer {.
    importcpp: "#->sink().packet_content(@)".}
  let cid = pkt.cid
  case pkt.operation
  of PUT:
    try:
      var
        pktBuf = session.cpp.packetContent pkt
        heapBuf = newString pkt.len
      copyMem(heapBuf[0].addr, pktBuf, heapBuf.len)
      let putCid = session.store.put(heapBuf)
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

proc newSession(env: GenodeEnv; store: DagfsStore; id: ServerId; label, args: string): Session =
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
      proc getPacket(cpp: SessionCpp): DagfsPacket {.
        importcpp: "#->sink().get_packet()".}
      var pkt = session.cpp.getPacket()
      session.processPacket pkt
      proc acknowledgePacket(cpp: SessionCpp; pkt: DagfsPacket) {.
        importcpp: "#->sink().acknowledge_packet(@)".}
      session.cpp.acknowledgePacket(pkt)

  proc packetHandler(cpp: SessionCpp; cap: SignalContextCapability) {.
    importcpp: "#->packetHandler(@)".}
  session.cpp.packetHandler(session.sig.cap)
  result = session

proc manage(ep: Entrypoint; s: Session): DagfsSessionCapability =
  ## Manage a session from the default entrypoint.
  proc manage(ep: Entrypoint; cpp: SessionCpp): DagfsSessionCapability {.
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
  DagfsServer* = ref object
    env: GenodeEnv
    store*: DagfsStore
    sessions*: Table[ServerId, Session]

proc newDagfsServer*(env: GenodeEnv; store: DagfsStore): DagfsServer =
  DagfsServer(
    env: env, store: store,
    sessions: initTable[ServerId, Session]())

proc create*(server: DagfsServer; id: ServerId; label, args: string) =
  if not server.sessions.contains id:
    try:
      let
        session = newSession(server.env, server.store, id, label, args)
        cap = server.env.ep.manage(session)
      server.sessions[id] = session
      proc deliverSession(env: GenodeEnv; id: ServerId; cap: DagfsSessionCapability) {.
        importcpp: "#->parent().deliver_session_cap(Genode::Parent::Server::Id{#}, #)".}
      server.env.deliverSession(id, cap)
      echo "session opened for ", label
    except:
      echo "failed to create session for '", label, "', ", getCurrentExceptionMsg()
      server.env.parent.sessionResponseDeny id

proc close*(server: DagfsServer; id: ServerId) =
  ## Close a session at the Dagfs server.
  if server.sessions.contains id:
    let session = server.sessions[id]
    server.env.ep.dissolve(session)
    server.sessions.del id
    server.env.parent.sessionResponseClose id
