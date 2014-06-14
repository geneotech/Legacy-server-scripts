dofile "config.lua"

print "Initialization successful."

ENGINE_DIRECTORY = "..\\..\\Augmentations\\scripts\\"
dofile (ENGINE_DIRECTORY .. "load_libraries.lua")

server = network_interface()
server:listen(37017, 6, 10)

received = network_packet()

user_map = guid_to_object_map()

dofile "server\\client.lua"

CLIENT_CODE_DIRECTORY = "..\\..\\Hypersomnia\\output\\hypersomnia\\"
MAPS_DIRECTORY = CLIENT_CODE_DIRECTORY .. "data\\maps\\"

dofile (CLIENT_CODE_DIRECTORY .. "scripts\\game\\layers.lua")
dofile (CLIENT_CODE_DIRECTORY .. "scripts\\game\\filters.lua")

dofile "server\\view\\input.lua"
dofile "server\\view\\camera.lua"

sample_scene = scene_class:create()
sample_scene:load_map(MAPS_DIRECTORY .. "sample_map.lua", "server\\loaders\\basic_map_loader.lua")

SHOULD_QUIT_FLAG = false

while not SHOULD_QUIT_FLAG do
	if server:receive(received) then
		local message_type = received:byte(0)
		if message_type == network_message.ID_NEW_INCOMING_CONNECTION then
			user_map:add(received:guid(), client_class:create())
			print "A connection is incoming."
			print (user_map:size())
		elseif message_type == network_message.ID_DISCONNECTION_NOTIFICATION then
			user_map:remove(received:guid())
			print "A client has disconnected."
			print (user_map:size())
		elseif message_type == network_message.ID_CONNECTION_LOST then
			user_map:remove(received:guid())
			print "A client lost the connection."
			print (user_map:size())
		else
			user_map:at(received:guid()):handle_message(received)
		end
	end
	
	
	-- tick the game world
	sample_scene:loop()
end
