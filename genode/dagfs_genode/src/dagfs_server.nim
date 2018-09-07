#
# \brief  Dagfs routing server
# \author Emery Hemingway
# \date   2017-11-11
#

#
# Copyright (C) 2017-2018 Genode Labs GmbH
#
# This file is part of the Genode OS framework, which is distributed
# under the terms of the GNU Affero General Public License version 3.
#

import std/strtabs, std/tables, std/xmltree, std/strutils, std/deques

import dagfs, dagfs/stores, ./dagfs_session,
  genode, genode/signals, genode/servers, genode/parents, genode/roms

const
  currentPath = currentSourcePath.rsplit("/", 1)[0]
  dagfsserverH = currentPath & "/dagfs_server.h"
{.passC: "-I" & currentPath & "/../../include".}

type
  DagfsSessionComponentBase {.importcpp, header: dagfsserverH.} = object
  SessionCpp = Constructible[DagfsSessionComponentBase]

proc construct(cpp: SessionCpp; env: GenodeEnv; args: cstring) {.importcpp.}

proc packetHandler(cpp: SessionCpp; cap: SignalContextCapability) {.
  importcpp: "#->packetHandler(@)".}

proc packetContent(cpp: SessionCpp; pkt: DagfsPacket): pointer {.
  importcpp: "#->sink().packet_content(@)".}

proc packetAvail(cpp: SessionCpp): bool {.
  importcpp: "#->sink().packet_avail()".}

proc readyToAck(cpp: SessionCpp): bool {.
  importcpp: "#->sink().ready_to_ack()".}

proc peekPacket(cpp: SessionCpp): DagfsPacket {.
  importcpp: "#->sink().peek_packet()".}

proc getPacket(cpp: SessionCpp): DagfsPacket {.
  importcpp: "#->sink().get_packet()".}

proc acknowledgePacket(cpp: SessionCpp; pkt: DagfsPacket) {.
  importcpp: "#->sink().acknowledge_packet(@)".}

proc acknowledgePacket(cpp: SessionCpp; pkt: DagfsPacket; cid: cstring; op: DagfsOpcode) {.
  importcpp: "#->sink().acknowledge_packet(Dagfs::Packet(#, (char const *)#, #))".}

template acknowledgePacket(cpp: SessionCpp; pkt: DagfsPacket; cid: Cid; op: DagfsOpcode) =
  acknowledgePacket(cpp, pkt, cid.toHex, op)

type
  Session = ref SessionObj
  SessionObj = object of RootObj
    cpp: SessionCpp
    sig: SignalHandler
    label: string

  Frontend = ref object of SessionObj
    discard

  Backend = ref object of SessionObj
    idle: Deque[DagfsPacket]
    prio: int

  Frontends = OrderedTableRef[ServerId, Frontend]
  Backends = OrderedTableRef[ServerId, Backend]

proc `$`(s: Session): string = s.label

proc submitGet*(bend: Backend; cid: Cid): bool =
  if 0 < bend.idle.len:
    let pkt = bend.idle.popFirst()
    bend.cpp.acknowledgePacket(pkt, cid, GET)
    result = true

proc submitPut*(bend: Backend; cid: Cid; buf: pointer; len: int): bool =
  if 0 < bend.idle.len:
    var pkt = bend.idle.popFirst()
    copyMem(bend.cpp.packetContent(pkt), buf, len)
    pkt.setLen(len)
    bend.cpp.acknowledgePacket(pkt, cid, PUT)
    result = true

proc isPending(fend: Frontend; cid: Cid): bool =
  if fend.cpp.packetAvail and fend.cpp.readyToAck:
    result = (cid == fend.cpp.peekPacket.cid)

proc isPending(fend: Session; cid: Cid; op: DagfsOpcode): bool =
  if fend.cpp.packetAvail and fend.cpp.readyToAck:
    let pkt = fend.cpp.peekPacket()
    result = (pkt.operation == op and cid == pkt.cid)

proc processPacket(backends: Backends; fend: Frontend): bool =
  if backends.len < 1:
    echo "cannot service frontend client, no backends connected"
    var pkt = fend.cpp.getPacket
    pkt.setError MISSING
    fend.cpp.acknowledgePacket(pkt)
    return true
  let
    pkt = fend.cpp.peekPacket
    cid = pkt.cid
    op = pkt.operation
  case op
  of GET:
    for bend in backends.values:
      if bend.submitGet(cid):
        break
  of PUT:
    let
      buf = fend.cpp.packetContent(pkt)
      len = pkt.len
    for bend in backends.values:
      if bend.submitPut(cid, buf, len):
        break
  else:
    var ack = fend.cpp.getPacket()
    ack.setError ERROR
    fend.cpp.acknowledgePacket(ack)
    result = true

proc processPacket(frontends: Frontends; bend: Backend): bool =
  let
    pkt = bend.cpp.getPacket
    cid = pkt.cid
    op = pkt.operation
  case op
  of PUT:
    assert(0 < pkt.len)
    for fend in frontends.values:
      if fend.isPending(cid, GET):
        var ack = fend.cpp.getPacket
        if ack.size < pkt.len:
          ack.setError(OVERSIZE)
          fend.cpp.acknowledgePacket(ack)
        else:
          ack.setLen(pkt.len)
          copyMem(fend.cpp.packetContent(ack), bend.cpp.packetContent(pkt), ack.len)
          fend.cpp.acknowledgePacket(ack, cid, PUT)
  of IDLE:
    for fend in frontends.values:
      if fend.isPending(cid, PUT):
        fend.cpp.acknowledgePacket(fend.cpp.getPacket, cid, IDLE)
  else:
    echo "invalid backend packet operation from ", bend.label
  bend.idle.addLast pkt
  true

proc newFrontend(env: GenodeEnv; backends: Backends; args, label: string): Frontend =
  let fend = Frontend(label: label)
  fend.cpp.construct(env, args)
  fend.sig = env.ep.newSignalHandler do ():
    while fend.cpp.packetAvail and fend.cpp.readyToAck:
      if not backends.processPacket(fend): break
  fend.cpp.packetHandler(fend.sig.cap)
  fend

proc newBackend(env: GenodeEnv; frontends: Frontends; args: string; prio: int; label: string): Backend =
  let bend = Backend(
    label: label,
    idle: initDeque[DagfsPacket](),
    prio: prio)
  bend.cpp.construct(env, args)
  bend.sig = env.ep.newSignalHandler do ():
    assert(bend.cpp.packetAvail, $bend & " signaled but no packet avail")
    assert(bend.cpp.readyToAck, $bend & " signaled but not ready to ack")
    while bend.cpp.packetAvail and bend.cpp.readyToAck:
      if not frontends.processPacket(bend): break
  bend.cpp.packetHandler(bend.sig.cap)
  bend

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

componentConstructHook = proc(env: GenodeEnv) =
  var
    policies = newSeq[XmlNode]()
    backends = newOrderedTable[ServerId, Backend]()
    frontends = newOrderedTable[ServerId, Frontend]()

  proc processConfig(rom: RomClient) {.gcsafe.} =
    update rom
    policies.setLen 0
    let configXml = rom.xml
    configXml.findAll("default-policy", policies)
    if policies.len > 1:
      echo "more than one '<default-policy/>' found, ignoring all"
      policies.setLen 0
    configXml.findAll("policy", policies)

  proc processSessions(rom: RomClient) =
    update rom
    var requests = initSessionRequestsParser(rom)

    for id in requests.close:
      var s: Session
      if frontends.contains id:
        s = frontends[id]
        frontends.del id
      elif backends.contains id:
        s = backends[id]
        backends.del id
      env.ep.dissolve s
      env.parent.sessionResponseClose(id)

    for id, label, args in requests.create "Dagfs":
      let policy = policies.lookupPolicy label
      if policy.isNil:
        echo "no policy matched '", label, "'"
        env.parent.sessionResponseDeny(id)
      else:
        var session: Session
        let role = policy.attr("role")
        case role
        of "frontend":
          let fend = newFrontend(env, backends, args, label)
          frontends[id] = fend
          session = fend
        of "backend":
          var prio = 1
          try: prio = policy.attr("prio").parseInt
          except: discard
          let bend = newBackend(env, frontends, args, prio, label)
          backends[id] = bend
          backends.sort(proc (x, y: (ServerId, Backend)): int =
            x[1].prio - y[1].prio)
          session = bend
        else:
          echo "invalid role for policy ", policy
          env.parent.sessionResponseDeny(id)
          continue
        let cap = env.ep.manage(session)
        proc deliverSession(env: GenodeEnv; id: ServerId; cap: DagfsSessionCapability) {.
          importcpp: "#->parent().deliver_session_cap(Genode::Parent::Server::Id{#}, #)".}
        env.deliverSession(id, cap)
        echo "session opened for ", label

  let
    sessionsRom = env.newRomHandler("session_requests", processSessions)
    configRom = env.newRomHandler("config", processConfig)
  process configRom
  process sessionsRom
