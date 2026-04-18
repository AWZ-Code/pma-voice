local disableUpdates = false
local isListenerEnabled = false
local plyCoords = GetEntityCoords(PlayerPedId())
local CHECK = true

function orig_addProximityCheck(ply)
	local tgtPed = GetPlayerPed(ply)
	local voiceModeData = Cfg.voiceModes[mode]
	local distance = GetConvar('voice_useNativeAudio', 'false') == 'true' and voiceModeData[1] * 3 or voiceModeData[1]
	return #(plyCoords - GetEntityCoords(tgtPed)) < distance
end
local addProximityCheck = orig_addProximityCheck

exports("overrideProximityCheck", function(fn)
	addProximityCheck = fn
end)

exports("resetProximityCheck", function()
	addProximityCheck = orig_addProximityCheck
end)

function addNearbyPlayers()
	if disableUpdates then return end
	-- update here so we don't have to update every call of addProximityCheck
	plyCoords = GetEntityCoords(PlayerPedId())

	MumbleClearVoiceTargetChannels(voiceTarget)
	local players = GetActivePlayers()
	for i = 1, #players do
		local ply = players[i]
		local serverId = GetPlayerServerId(ply)
        
		if not IsEntityDead(PlayerPedId()) then
            if addProximityCheck(ply) then
                if isTarget then goto skip_loop end
                logger.verbose('Added %s as a voice target', serverId)
                MumbleAddVoiceTargetChannel(voiceTarget, serverId)
            end
        end
        
		if not IsEntityDead(PlayerPedId()) and CHECK then
            CHECK = false
			handleInitialState()
		elseif IsEntityDead(PlayerPedId()) and not CHECK then
            CHECK = true
			MumbleSetVoiceChannel(999)
		end
		::skip_loop::
	end
end

function setSpectatorMode(enabled)
	logger.info('Setting spectate mode to %s', enabled)
	isListenerEnabled = enabled
	local players = GetActivePlayers()
	if isListenerEnabled then
		for i = 1, #players do
			local ply = players[i]
			local serverId = GetPlayerServerId(ply)
			if serverId == playerServerId then goto skip_loop end
			logger.verbose("Adding %s to listen table", serverId)
			MumbleAddVoiceChannelListen(serverId)
			::skip_loop::
		end
	else

	end
end

RegisterNetEvent('onPlayerJoining', function(serverId)
	if isListenerEnabled then
		MumbleAddVoiceChannelListen(serverId)
		logger.verbose("Adding %s to listen table", serverId)
	end
end)

RegisterNetEvent('onPlayerDropped', function(serverId)
	if isListenerEnabled then
		MumbleRemoveVoiceChannelListen(serverId)
		logger.verbose("Removing %s from listen table", serverId)
	end
end)

-- cache talking status so we only send a nui message when its not the same as what it was before
local lastTalkingStatus = false
local lastRadioStatus = false
local lastMutedStatus = false
local lastRangeDistance = nil
local voiceState = "proximity"
CreateThread(function()
	TriggerEvent('chat:addSuggestion', '/muteply', 'Mutes the player with the specified id', {
		{ name = "player id", help = "the player to toggle mute" },
		{ name = "duration", help = "(opt) the duration the mute in seconds (default: 900)" }
	})
	while true do
		-- wait for mumble to reconnect
		while not MumbleIsConnected() do
			Wait(100)
		end
		-- Leave the check here as we don't want to do any of this logic 
		if GetConvarInt('voice_enableUi', 1) == 1 then
			local curTalkingStatus = MumbleIsPlayerTalking(PlayerId()) == 1
			local curMutedStatus = LocalPlayer.state.muted == true
			local prox = LocalPlayer.state.proximity
			local curRangeDistance = prox and prox.distance or nil
			if lastRadioStatus ~= radioPressed or lastTalkingStatus ~= curTalkingStatus then
				lastRadioStatus = radioPressed
				lastTalkingStatus = curTalkingStatus
				sendUIMessage({
					usingRadio = lastRadioStatus,
					talking = lastTalkingStatus
				})
				TriggerEvent('hud:isTalking', lastTalkingStatus)
			end
			if lastMutedStatus ~= curMutedStatus then
				lastMutedStatus = curMutedStatus
				TriggerEvent('pma-voice:muted', lastMutedStatus)
				TriggerEvent('hud:setMuted', lastMutedStatus)
			end
			if curRangeDistance and lastRangeDistance ~= curRangeDistance then
				lastRangeDistance = curRangeDistance
				-- AWZ: keep the cached range in sync, but do not re-emit hud:changeRadius here.
				-- The primary emit already happens in setProximityState()/mumbleConnected;
				-- re-emitting from this polling loop causes a second circle spawn ~1s later.
			end
		end

		if voiceState == "proximity" then
			addNearbyPlayers()
			local isSpectating = NetworkIsInSpectatorMode()
			if isSpectating and not isListenerEnabled then
				setSpectatorMode(true)
			elseif not isSpectating and isListenerEnabled then
				setSpectatorMode(false)
			end
		end
		Wait(1000)
		Wait(GetConvarInt('voice_refreshRate', 200))
	end
end)

exports("setVoiceState", function(_voiceState, channel)
	if _voiceState ~= "proximity" and _voiceState ~= "channel" then
		logger.error("Didn't get a proper voice state, expected proximity or channel, got %s", _voiceState)
	end
	voiceState = _voiceState
	if voiceState == "channel" then
		type_check({channel, "number"})
		-- 65535 is the highest a client id can go, so we add that to the base channel so we don't manage to get onto a players channel
		channel = channel + 65535
		MumbleSetVoiceChannel(channel)
		while MumbleGetVoiceChannelFromServerId(playerServerId) ~= channel do
			Wait(250)
		end
		MumbleAddVoiceTargetChannel(voiceTarget, channel)
	elseif voiceState == "proximity" then
		handleInitialState()
	end
end)


AddEventHandler("onClientResourceStop", function(resource)
	if type(addProximityCheck) == "table" then
		local proximityCheckRef = addProximityCheck.__cfx_functionReference
		if proximityCheckRef then
			local isResource = string.match(proximityCheckRef, resource)
			if isResource then
				addProximityCheck = orig_addProximityCheck
				logger.warn('Reset proximity check to default, the original resource [%s] which provided the function restarted', resource)
			end
		end
	end
end)