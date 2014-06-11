#pragma once
#include "network/network_interface.h"

#include "game_framework/resources/lua_state_wrapper.h"
#include "game_framework/game_framework.h"

#include "utilities/error/error.h"

using namespace augs;

int main() {
	augs::global_log.open(L"engine_errors.txt");
	
	framework::init();

	resources::lua_state_wrapper lua_state;
	lua_state.bind_whole_engine();

	lua_state.dofile("init.lua"); 

	framework::deinit();
	return 0;
}  