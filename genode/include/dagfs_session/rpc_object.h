/*
 * \brief  Server-side Dagfs session interface
 * \author Emery Hemingway
 * \date   2017-11-04
 */

/*
 * Copyright (C) 2017 Genode Labs GmbH
 *
 * This file is part of the Genode OS framework, which is distributed
 * under the terms of the GNU Affero General Public License version 3.
 */

#ifndef _INCLUDE__DAGFS_SESSION__SERVER_H_
#define _INCLUDE__DAGFS_SESSION__SERVER_H_

#include <dagfs_session/dagfs_session.h>
#include <packet_stream_tx/rpc_object.h>
#include <base/rpc_server.h>

namespace Dagfs { class Session_rpc_object; }

class Dagfs::Session_rpc_object : public Genode::Rpc_object<Session, Session_rpc_object>
{
	protected:

		Packet_stream_tx::Rpc_object<Dagfs_channel> _tx;

	public:

		/**
		 * Constructor
		 *
		 * \param tx_ds  dataspace used as communication buffer
		 *               for the tx packet stream
		 * \param ep     entry point used for packet-stream channel
		 */
		Session_rpc_object(Genode::Region_map &rm,
		                   Genode::Rpc_entrypoint &ep,
		                   Genode::Dataspace_capability tx_ds)
		: _tx(tx_ds, rm, ep) { }

		/**
		 * Return capability to packet-stream channel
		 *
		 * This method is called by the client via an RPC call at session
		 * construction time.
		 */
		Genode::Capability<Dagfs_channel> _tx_cap() { return _tx.cap(); }

		Dagfs_channel::Sink &sink() { return *_tx.sink(); }
};

#endif /* _INCLUDE__DAGFS_SESSION__SERVER_H_ */
