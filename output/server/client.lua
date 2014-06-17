dofile (CLIENT_CODE_DIRECTORY .. "scripts\\network_commands.lua")

client_class = inherits_from ()

name_to_intent = {}
command_to_name = {}

for k, v in pairs (name_to_command) do
	command_to_name[v] = k
end

for k, v in pairs (intent_to_name) do
	name_to_intent[v] = k
end


function client_class:constructor(owner_scene, guid)
	self.position_history = {}
	self.guid = guid
	
	-- create new entity here
	self.controlled_character = create_basic_player(owner_scene, teleport_position)
	print "A connection is incoming."
	
	-- firstly notify this one about the game state
	local bsOut = BitStream()
	bsOut:WriteByte(UnsignedChar(network_message.ID_INITIAL_STATE))
	WriteUint(bsOut, user_map:size())
	
	for i=1, #all_clients do
		WriteRakNetGUID(bsOut, all_clients[i].guid)
	end
	
	server:send(bsOut, send_priority.HIGH_PRIORITY, send_reliability.RELIABLE_ORDERED, 0, guid, false)
	
	bsOut = BitStream()
	bsOut:WriteByte(UnsignedChar(network_message.ID_NEW_PLAYER))
	WriteRakNetGUID(bsOut, guid)
	
	-- notify all others that the client was created
	server:send(bsOut, send_priority.HIGH_PRIORITY, send_reliability.RELIABLE_ORDERED, 0, guid, true)
end


function client_class:close_connection()
	sample_scene.world_object.world:delete_entity(self.controlled_character.parent_entity:get(), nil)

	for i=1, #all_clients do
		if all_clients[i] == self then
			table.remove(all_clients, i)
			break
		end
	end
	
	local bsOut = BitStream()
	print(network_message.ID_PLAYER_DISCONNECTED)
	bsOut:WriteByte(UnsignedChar(network_message.ID_PLAYER_DISCONNECTED))
	WriteRakNetGUID(bsOut, self.guid)
	
	-- notify all but disconnected one
	server:send(bsOut, send_priority.HIGH_PRIORITY, send_reliability.RELIABLE_ORDERED, 0, self.guid, true)
end

function client_class:handle_message(received)
	local message_type = received:byte(0)
	
	if message_type == network_message.ID_COMMAND then
		local bsIn = received:get_bitstream()
		-- bsIn:IgnoreBytes(1)
		local command_name = command_to_name[received:byte(1)]
		
		self.controlled_character:handle_command(command_name)
	else
		print ("Message with identifier " .. message_type .. " has arrived.")
	end
end