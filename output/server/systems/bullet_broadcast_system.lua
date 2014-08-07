bullet_broadcast_system = inherits_from (processing_system)

function bullet_broadcast_system:constructor()
	self.next_bullet_global_id = 1
end

function bullet_broadcast_system:translate_shot_requests()
	local msgs = self.owner_entity_system.messages["SHOT_REQUEST"]
	
	for i=1, #msgs do
		local character = msgs[i].subject.client.controlled_object
		local wielded_item = character.wield.wielded_item
	
		if wielded_item ~= nil and wielded_item.weapon ~= nil then
			table.insert(wielded_item.weapon.buffered_actions, { trigger = components.weapon.triggers.SHOOT, premade_shot = {
				position = msgs[i].data.position,
				rotation = msgs[i].data.rotation
			}})
		end
	end
end

function bullet_broadcast_system:invalidate_old_bullets(subject)
	for k, v in pairs(subject.local_bullet_id_to_global) do
		if v.lifetime:get_milliseconds() > v.max_lifetime_ms then
			subject.local_bullet_id_to_global[k] = nil
			print "invalidating"
		end
	end
end

function bullet_broadcast_system:handle_hit_requests()
	local msgs = self.owner_entity_system.messages["HIT_REQUEST"]
	
	local objects = self.owner_entity_system.all_systems["replication"].object_by_id
	
	for i=1, #msgs do
		print "received hit request"
		--print (msgs[i].data.bullet_id)
		--print (msgs[i].data.victim_id)
		--print (msgs[i].subject.weapon.existing_bullets[msgs[i].data.bullet_id] ~= nil)
		--print (objects[msgs[i].data.victim_id] ~= nil)
		
		
		local msg = msgs[i]
		local subject = msg.subject
		local client = subject.client
		
		self:invalidate_old_bullets(client)
		
		local local_bullet_id = msg.data.bullet_id
		local existing_bullets = client.local_bullet_id_to_global
		local victim = objects[msg.data.victim_id]
		local bullet = existing_bullets[local_bullet_id]
		
		if victim ~= nil and bullet ~= nil then
			-- the sender themself will know only about the damage applied so exclude him now
			victim.replication:broadcast_reliable(protocol.write_msg("HIT_INFO", {
				victim_id = victim.replication.id,
				bullet_id = bullet.global_id
			}), subject)
					
			if victim.health ~= nil then
				if victim.health.hp - bullet.damage_amount < 0 then
					bullet.damage_amount = victim.health.hp
				end
				
				if bullet.damage_amount > 0 then
					victim.health.hp = victim.health.hp - bullet.damage_amount
					
					victim.replication:broadcast_reliable(protocol.write_msg("DAMAGE_MESSAGE", {
						victim_id = victim.replication.id,
						amount = bullet.damage_amount
					}))
						
					if victim.health.hp <= 0 then
						victim.health.hp = 0
						
						victim.health.on_death(victim)	
					end
				end
			end
		
			existing_bullets[local_bullet_id] = nil
		end
	end
end

function bullet_broadcast_system:broadcast_bullets(update_time_remaining)
	local msgs = self.owner_entity_system.messages["shot_message"]
	if update_time_remaining < 0 then update_time_remaining = 0 end
	
	for i=1, #msgs do
		-- here, we should perform a proximity check for the processed bullet(s)
		local subject = msgs[i].subject
		local character = subject.item.ownership
		local client_entity = character.client_controller.owner_client
		local client = client_entity.client
		
		-- invalidate old bullets as we go
		self:invalidate_old_bullets(client)
		
		-- save all new bullets for later invalidation
		-- and hit request handling
		
		local first_global_id = self.next_bullet_global_id
		local first_local_id = client.next_bullet_local_id
		
		for j=1, #msgs[i].bullets do
			client.local_bullet_id_to_global[client.next_bullet_local_id] = {
				global_id = self.next_bullet_global_id,
				lifetime = timer(),
				max_lifetime_ms = subject.weapon.max_lifetime_ms,
				damage_amount = subject.weapon.bullet_damage
			}
			
			-- keep in sync with the client
			client.next_bullet_local_id = client.next_bullet_local_id + 1
			self.next_bullet_global_id = self.next_bullet_global_id + 1
		end
		
		local client_sys = self.owner_entity_system.all_systems["client"]
		local all_clients = client_sys.targets
		
		for j=1, #all_clients do
			if client_entity ~= all_clients[j] then
				all_clients[j].client.net_channel:post_reliable("SHOT_INFO", {
					delay_time = client_sys.network:get_last_ping(client.guid)/2 + update_time_remaining,
					subject_id = character.replication.id,
					position = msgs[i].gun_transform.pos,
					rotation = msgs[i].gun_transform.rotation,
					starting_bullet_id = first_global_id,
					random_seed = character.replication.id*10 + first_local_id
				})
			end
			
		end
	end
end