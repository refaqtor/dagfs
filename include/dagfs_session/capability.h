/*
 * \brief  Dagfs session capability type
 * \author Emery Hemingway
 * \date   2017-11-07
 */

/*
 * Copyright (C) 2017 Genode Labs GmbH
 *
 * This file is part of the Genode OS framework, which is distributed
 * under the terms of the GNU Affero General Public License version 3.
 */

#ifndef _INCLUDE__DAGFS_SESSION__CAPABILITY_H_
#define _INCLUDE__DAGFS_SESSION__CAPABILITY_H_

#include <base/capability.h>
#include <dagfs_session/dagfs_session.h>

namespace Dagfs { typedef Genode::Capability<Session> Session_capability; }

#endif /* _INCLUDE__DAGFS_SESSION__CAPABILITY_H_ */
