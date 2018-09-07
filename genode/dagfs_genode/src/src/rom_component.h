/*
 * \brief  C++ ROM session component
 * \author Emery Hemingway
 * \date   2017-10-03
 */

/*
 * Copyright (C) 2017 Genode Labs GmbH
 *
 * This file is part of the Genode OS framework, which is distributed
 * under the terms of the GNU Affero General Public License version 3.
 */

/* Genode includes */
#include <rom_session/rom_session.h>
#include <base/rpc_server.h>

struct RomSessionComponentBase :
	Genode::Rpc_object<Genode::Rom_session>
{
	Genode::Dataspace_capability const rom_ds;

	RomSessionComponentBase(Genode::Dataspace_capability ds)
	: rom_ds(ds) { }


	/***************************
	 ** ROM session interface **
	 ***************************/

	Genode::Rom_dataspace_capability dataspace() override { return rom_ds; }

	void sigh(Genode::Signal_context_capability sigh) { }
};
