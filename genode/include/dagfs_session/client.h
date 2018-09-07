/*
 * \brief  Client-side Dagfs session interface
 * \author Emery Hemingway
 * \date   2017-11-07
 */

/*
 * Copyright (C) 2017 Genode Labs GmbH
 *
 * This file is part of the Genode OS framework, which is distributed
 * under the terms of the GNU Affero General Public License version 3.
 */

#ifndef _INCLUDE__DAGFS_SESSION__CLIENT_H_
#define _INCLUDE__DAGFS_SESSION__CLIENT_H_

#include <dagfs_session/capability.h>
#include <packet_stream_tx/client.h>
#include <base/rpc_client.h>

namespace Dagfs { class Session_client; }


class Dagfs::Session_client : public Genode::Rpc_client<Session>
{
	private:

		Packet_stream_tx::Client<Dagfs_channel> _tx;

	public:

		/**
		 * Constructor
		 */
		Session_client(Session_capability       session,
		               Genode::Region_map      &rm,
		               Genode::Range_allocator &tx_buffer_alloc)
		:
			Genode::Rpc_client<Session>(session),
			_tx(call<Rpc_tx_cap>(), rm, tx_buffer_alloc)
		{ }


		/***************************
		 ** Dagfs session interface **
		 ***************************/

		Dagfs_channel &channel() { return _tx; }
		Dagfs_channel::Source &source() { return *_tx.source(); }
};

#endif /* _INCLUDE__DAGFS_SESSION__CLIENT_H_ */
