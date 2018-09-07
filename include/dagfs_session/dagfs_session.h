/*
 * \brief  Dagfs session interface
 * \author Emery Hemingway
 * \date   2017-11-07
 */

/*
 * Copyright (C) 2017 Genode Labs GmbH
 *
 * This file is part of the Genode OS framework, which is distributed
 * under the terms of the GNU Affero General Public License version 3.
 */

#ifndef _INCLUDE__DAGFS_SESSION__DAGFS_SESSION_H_
#define _INCLUDE__DAGFS_SESSION__DAGFS_SESSION_H_

#include <packet_stream_tx/packet_stream_tx.h>
#include <session/session.h>
#include <base/rpc.h>

namespace Dagfs {

	struct Packet;
	struct Session;

	enum {
		MAX_CID_LEN = 96, /* enough for a CID with a 256 bit digest */
		MAX_BLOCK_SIZE = 1 << 18, /* ¼ MiB */
	};

	/* Content identifier embedded in DAGFS packets */
	typedef Genode::String<MAX_CID_LEN> Cid;

}


/**
 * Packet carrying a request or response
 */
struct Dagfs::Packet final : Genode::Packet_descriptor
{
	enum Opcode { PUT, GET, INVALID };

	enum Error {
		OK,       /* put or get success */
		MISSING,  /* no block found for get request */
		OVERSIZE, /* get response is larger than packet buffer */
		FULL,     /* put failed due to storage exhaustion */
		ERROR     /* unspecified error */
	};

	Cid            _cid;
	Genode::size_t _length = 0;
	Opcode         _op = INVALID;
	Error          _err;

	Packet(Genode::off_t offset=0, Genode::size_t size = 0)
	: Genode::Packet_descriptor(offset, size), _op(INVALID) { }

	Packet(Packet p, Cid cid, Opcode op)
	:
		Genode::Packet_descriptor(p.offset(), p.size()),
		_cid(cid),  _length(p.size()), _op(op), _err(OK)
	{ }

	Packet(Cid cid, Genode::size_t length,
	       Opcode op, Error err = OK)
	:
		Genode::Packet_descriptor(0, 0),
		_cid(cid), _length(length), _op(op), _err(err)
	{ }

	Cid   const &cid() const { return _cid;    }
	Opcode operation() const { return _op;     }
	size_t    length() const { return _length; }
	Error      error() const { return _err;    }

	void cid(char const *hex)  { _cid = Cid(hex); }
	void length(size_t len) { _length = len; }
	void  error(Error err)  {    _err = err; }
};


/*
 * DAGFS session interface
 *
 * An DAGFS session stores or retrieves DAGFS blocks via an asynchrous
 * packet-stream interface.
 */
struct Dagfs::Session : Genode::Session
{
	enum { QUEUE_SIZE = 8 };

	typedef Genode::Packet_stream_policy<
		Dagfs::Packet, QUEUE_SIZE, QUEUE_SIZE, char> Policy;

	typedef Packet_stream_tx::Channel<Policy> Dagfs_channel;

	/**
	 * \noapi
	 */
	static const char *service_name() { return "Dagfs"; }

	/*
	 * An DAGFS session consumes a dataspace capability for the server-side
	 * session object, a session capability, a packet-stream dataspace,
	 * and two signal context capabilities for data-flow signals.
	 */
	enum { CAP_QUOTA = 6 };

	virtual ~Session() { }

	/*******************
	 ** RPC interface **
	 *******************/

	GENODE_RPC(Rpc_tx_cap, Genode::Capability<Dagfs_channel>, _tx_cap);

	GENODE_RPC_INTERFACE(Rpc_tx_cap);
};

#endif /* _INCLUDE__DAGFS_SESSION__DAGFS_SESSION_H_ */
