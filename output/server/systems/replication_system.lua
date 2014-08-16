replication_system = inherits_from (processing_system)

function components.replication:broadcast_reliable(output_bs, exclude_client)
	for client_entity, v in pairs(self.remote_states) do
		if client_entity ~= exclude_client then
			client_entity.client.net_channel:post_reliable_bs(output_bs)
		end
	end		
end

function components.replication:switch_public_group(new_public_group)
	self.public_group_name = new_public_group
end


function components.replication:clear_group_for_client(target_client)
	self:switch_group_for_client(self.public_group_name, target_client)
end

function components.replication:switch_group_for_client(new_group, target_client)
	local remote_state = self.remote_states[target_client]

	if new_group == self.public_group_name then
		-- simply map it to whatever public group later will this object specify
		target_client.client.group_by_id[self.id] = nil
	else
		target_client.client.group_by_id[self.id] = new_group
	end
end

function replication_system:constructor() 
	self.transmission_id_generator = id_generator_ushort()
	self.object_by_id = {}
	
	processing_system.constructor(self)
end

function replication_system:get_required_components()
	return { "replication" }
end

function replication_system:get_targets_of_interest(subject_client)
	-- here should follow proximity checks
	
	-- pseudo proximity taking only objects with physics components
	local proximity_targets = {}
	
	for i=1, #self.targets do
		if self.targets[i].cpp_entity.physics ~= nil then
			proximity_targets[#proximity_targets + 1] = self.targets[i]
		end
	end
	
	return proximity_targets
end

function replication_system:update_replicas()
	for i=1, #self.targets do
		for k, group in pairs(self.targets[i].replication.module_sets) do
			for key, module_object in pairs(group.replica) do
				-- setup dirty flags
				module_object:replicate(self.targets[i])
			end
		end
	end
end

function replication_system:write_new_object(id, archetype_id, replica, output_bs)
	protocol.write_sig(protocol.new_object_signature, {
		["id"] = id,
		["archetype_id"] = archetype_id
	}, output_bs)
	
	local initial_state_bs = BitStream()
	
	for i=1, #protocol.module_mappings do
		output_bs:name_property("has module " .. i)
		
		local module_object = replica[protocol.module_mappings[i]]
		
		output_bs:WriteBit(module_object ~= nil)
		
		if module_object ~= nil then
			module_object:write_initial_state(self.object_by_id[id], initial_state_bs)
		end
	end
	
	output_bs:name_property("initial_state_bs")
	output_bs:WriteBitstream(initial_state_bs)
end
					
function replication_system:write_object_state(id, replica, dirty_flags, client_channel, output_bs)
	local content_bs = BitStream()
	
	content_bs:name_property("object_id")
	content_bs:WriteUshort(id)
	
	local modules_updated = 0
	
	for j=1, #protocol.module_mappings do
		local module_name = protocol.module_mappings[j]
		
		local module_object = replica[module_name]
		
		if module_object ~= nil then
			module_object:update_flags(dirty_flags[module_name], client_channel:next_unreliable_sequence(), client_channel:unreliable_ack())
			
			if module_object:write_state(dirty_flags[module_name], content_bs) then	
				modules_updated = modules_updated + 1 
			end
		end
	end
	
	if modules_updated > 0 then
		output_bs:WriteBitstream(content_bs)
	end
	
	return modules_updated
end

function replication_system:update_state_for_client(subject_client, post_recent_state, custom_targets)
	local client_channel = subject_client.client.net_channel
	local targets_of_interest = self:get_targets_of_interest(subject_client)
	
	if custom_targets ~= nil then
		targets_of_interest = custom_targets
	end
	
	if #targets_of_interest > 0 then
		local new_objects = BitStream()
		local updated_objects = BitStream()
		
		local num_new_objects = 0
		local num_updated_objects = 0
		
		
		local num_targets = #targets_of_interest
		
		for i=1, num_targets do
			local replication = targets_of_interest[i].replication
			local dependent_entities = replication.sub_entities
					
			for k, v in pairs (dependent_entities) do
				targets_of_interest[#targets_of_interest + 1] = v
			end
			
			for group_name, group_table in pairs(replication.sub_entity_groups) do
				for k, v in pairs(group_table) do
					targets_of_interest[#targets_of_interest + 1] = v
				end
			end
		end
		
		local ids_processed = {}
		
		for i=1, #targets_of_interest do
			local target = targets_of_interest[i]
			local sync = target.replication
			local id = sync.id
			
			-- avoid handling duplicates
			if ids_processed[id] == nil then
				local states = sync.remote_states
				
				local target_group = subject_client.client.group_by_id[id]
				if target_group == nil then target_group = sync.public_group_name end
				
				local replica = sync.module_sets[target_group].replica
				local archetype_id = protocol.archetype_library[sync.module_sets[target_group].archetype_name]
				
				-- if the object doesn't exist on the remote peer
				-- or the group mismatches
				if states[subject_client] == nil or target_group ~= states[subject_client].group_name then
					num_new_objects = num_new_objects + 1	
					
					self:write_new_object(id, archetype_id, replica, new_objects)
					
					-- holds a set of dirty flags
					states[subject_client] = {
						dirty_flags = {},
						group_name = target_group
					}
					
					for k, v in pairs(replica) do
						-- hold dirty flags field-wise
						states[subject_client].dirty_flags[k] = v:get_all_marked(client_channel:next_unreliable_sequence())
					end
				end
				
				if post_recent_state then
					if self:write_object_state(id, replica, states[subject_client].dirty_flags, client_channel, updated_objects) > 0 then
						num_updated_objects = num_updated_objects + 1
					end
				end
				
				ids_processed[id] = true
			end
		end
		
		-- send existential events reliably
		if num_new_objects > 0 then	
			local output_bs = protocol.write_msg("NEW_OBJECTS", {
				object_count = num_new_objects,
				bits = new_objects:size()
			})
			
			output_bs:name_property("all new objects")
			output_bs:WriteBitstream(new_objects)
			
			client_channel:post_reliable_bs(output_bs)
		end
		
		if post_recent_state then
			-- send state updates reliably-sequenced
			if num_updated_objects > 0 then	
				local state_update_bs = protocol.write_msg("STATE_UPDATE", {
					object_count = num_updated_objects,
					bits = updated_objects:size()
				})
				
				state_update_bs:name_property("all objects")
				state_update_bs:WriteBitstream(updated_objects)
				
				client_channel.sender.request_ack_for_unreliable = true
				client_channel:post_unreliable_bs(state_update_bs)
			end
		end
	end
end

function replication_system:delete_client_states(removed_client)
	for i=1, #self.targets do
		self.targets[i].replication.remote_states[removed_client] = nil
	end
end

function replication_system:add_entity(new_entity)
	local new_id = self.transmission_id_generator:generate_id()
	new_entity.replication.id = new_id
	self.object_by_id[new_id] = new_entity
	
	if new_entity.client ~= nil then
		-- post a reliable message with an id of the replication object that will represent client info
		new_entity.client.net_channel:post_reliable("ASSIGN_SYNC_ID", { sync_id = new_id })
	end
	
	processing_system.add_entity(self, new_entity)
end

function replication_system:remove_entity(removed_entity)
	local removed_id = removed_entity.replication.id
	self.object_by_id[removed_id] = nil
	
	print ("removing " .. removed_id) 
	local remote_states = removed_entity.replication.remote_states
	
	local out_bs = protocol.write_msg("DELETE_OBJECT", { ["removed_id"] = removed_id } )
	-- sends delete notification to all clients to whom this object state was reliably sent at least once
	
	local new_remote_states = clone_table(remote_states)
	
	for notified_client, state in pairs(remote_states) do
		notified_client.client.net_channel:post_reliable_bs(out_bs)
		new_remote_states[notified_client] = nil
	end
	
	removed_entity.replication.remote_states = new_remote_states
	
	-- just in case, remove all occurences of group_by_id in connected clients
	-- this is necessary in case an object without alternative moduleset mapping was created
	-- and still the old group_by_id would map its id to an arbitrary group name
	
	local targets = self.owner_entity_system.all_systems["client"].targets
	
	for i=1, #targets do
		targets[i].client.group_by_id[removed_id] = nil
	end
	
	self.transmission_id_generator:release_id(removed_id)
	processing_system.remove_entity(self, removed_entity)
end

