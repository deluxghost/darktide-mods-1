local Audio = get_mod("Audio")
local io = Mods.lua.io
local LocalServer

local FFPLAY_FILENAME = "ffplay_dt.exe"
local FFPLAY_PATH = Audio.get_mod_path(Audio, "bin\\" .. FFPLAY_FILENAME, true)
local AUDIO_TYPE = table.enum("dialogue", "music", "sfx")
local PLAY_STATUS = table.enum("error", "fulfilled", "pending", "stopped", "success")

local played_files = {}

local log_errors = Audio:get("log_errors")

local player_unit
local first_person_component

local use_player_unit = function()
	if not Unit.alive(player_unit) then
		player_unit = Managers.player:local_player_safe(1).player_unit
	end
end

local use_first_person_component = function()
	if not first_person_component then
		local unit_data_extension = ScriptUnit.extension(player_unit, "unit_data_system")
		first_person_component = unit_data_extension:read_component("first_person")
	end
end

local calculate_distance_filter = function(
	unit_or_position,
	decay,
	min_distance,
	max_distance,
	override_position,
	override_rotation,
	node
)
	if not unit_or_position or not override_position or not override_rotation then
		use_player_unit()
	end

	if not override_rotation then
		use_first_person_component()
	end

	local position

	if not unit_or_position then
		position = Unit.local_position(player_unit, 1) or Vector3.zero()
	elseif type(unit_or_position) == "userdata" and Audio.userdata_type(unit_or_position) == "Unit" then
		position = Unit.local_position(unit_or_position, node or 1) or Vector3.zero()
	elseif type(unit_or_position) == "userdata" and Audio.userdata_type(unit_or_position) == "Vector3" then
		position = unit_or_position
	end

	local listener_position = override_position or Unit.local_position(player_unit, 1) or Vector3.zero()
	local listener_rotation = override_rotation or first_person_component.rotation or Quaternion.identity()

	decay = decay or 0.01
	min_distance = min_distance or 0
	max_distance = max_distance or 100

	local distance = Vector3.distance(position, listener_position)
	local volume

	if distance < min_distance then
		volume = 100
	elseif distance > max_distance then
		volume = 0
	else
		local ratio = 1 - math.clamp((distance - min_distance) / (max_distance - min_distance), 0, 1)

		volume = math.clamp(100 * (ratio - (distance - min_distance) * decay), 0, 100)
	end

	local direction = position - listener_position
	local directionRotated = Quaternion.rotate(Quaternion.inverse(listener_rotation), direction)
	local directionRotatedNormalized = Vector3.normalize(directionRotated)
	local angle = math.atan2(directionRotatedNormalized.x, directionRotatedNormalized.y)

	local pan

	if angle > 0 then
		if angle <= math.pi / 2 then
			pan = angle / (math.pi / 2)
		else
			pan = 1 - (angle - math.pi / 2) / (math.pi / 2)
		end
	else
		if angle >= -math.pi / 2 then
			pan = angle / (math.pi / 2)
		else
			pan = -(1 + (angle + math.pi / 2) / (math.pi / 2))
		end
	end

	local left_volume = pan > 0 and 1 - pan or 1
	local right_volume = pan < 0 and 1 + pan or 1

	return volume, left_volume, right_volume
end

local coroutine_kill = function()
	return coroutine.create(function(process_identifier)
		local identifier_type = type(process_identifier)
		local identifier = identifier_type == "string" and "/IM" or identifier_type == "number" and "/PID"
		while true do
			io.popen(string.format("taskkill /F %s %s", identifier, process_identifier)):close()

			coroutine.yield()
		end
	end)
end

local volume_adjustment = function(audio_type)
	local master_volume = Application.user_setting("sound_settings", "option_master_slider") / 100

	if not audio_type then
		return master_volume
	end

	if audio_type == AUDIO_TYPE.dialogue then
		local vo_trim = (Application.user_setting("sound_settings", "options_vo_trim") / 10) + 1

		return master_volume * vo_trim
	end

	if audio_type == AUDIO_TYPE.music then
		local music_volume = Application.user_setting("sound_settings", "options_music_slider") / 100

		return master_volume * music_volume
	end

	if audio_type == AUDIO_TYPE.sfx then
		local sfx_volume = Application.user_setting("sound_settings", "options_sfx_slider") / 100

		return master_volume * sfx_volume
	end
end

Audio.play_file = function(
	path,
	playback_settings,
	unit_or_position,
	decay,
	min_distance,
	max_distance,
	override_position,
	override_rotation
)
	playback_settings = playback_settings or {}

	local volume, left_volume, right_volume = calculate_distance_filter(
		unit_or_position,
		decay,
		min_distance,
		max_distance,
		override_position,
		override_rotation
	)

	local command = string.format(
		'%s -i "%s" -volume %s -af "pan=stereo|c0=%s*c0|c1=%s*c1 %s %s %s %s %s %s %s %s" %s %s %s -fast -nodisp -autoexit -loglevel quiet -hide_banner',
		FFPLAY_PATH,
		Audio.absolute_path(path),
		math.round(volume * volume_adjustment(playback_settings.audio_type)),
		left_volume,
		right_volume,
		playback_settings.adelay and (", adelay=" .. playback_settings.adelay) or "",
		playback_settings.aecho and (", aecho=" .. playback_settings.aecho) or "",
		playback_settings.afade and (", afade=" .. playback_settings.afade) or "",
		playback_settings.atempo and (", atempo=" .. playback_settings.atempo) or "",
		playback_settings.chorus and (", chorus=" .. playback_settings.chorus) or "",
		playback_settings.silenceremove and (", silenceremove=" .. playback_settings.silenceremove) or "",
		playback_settings.speechnorm and (", speechnorm=" .. playback_settings.speechnorm) or "",
		playback_settings.stereotools and (", stereotools=" .. playback_settings.stereotools) or "",
		playback_settings.loop and ("-loop " .. playback_settings.loop) or "",
		playback_settings.pos and ("-ss " .. playback_settings.pos) or "",
		playback_settings.duration and ("-t " .. playback_settings.duration) or ""
	)

	local play_file_id = #played_files + 1

	played_files[play_file_id] = {
		status = PLAY_STATUS.pending,
	}

	LocalServer.run_command(command)
		:next(function(result)
			local response = cjson.decode(result.body)

			played_files[play_file_id].status = response.success == true and PLAY_STATUS.success
				or PLAY_STATUS.fulfilled
			played_files[play_file_id].pid = response.pid
		end)
		:catch(function(error)
			played_files[play_file_id].status = PLAY_STATUS.error

			if not log_errors then
				return
			end

			local success = error.body and cjson.decode(error.body).success

			if success == false then
				Audio:dump({
					command = command,
					status = error.status,
					body = error.body,
					description = error.description,
					headers = error.headers,
					response_time = error.response_time,
				}, string.format("Server run command failed: %s", os.date()), 2)
			end
		end)

	return play_file_id, command
end

Audio.stop_file = function(play_file_id)
	local pid = play_file_id and played_files[play_file_id] and played_files[play_file_id].pid

	coroutine.resume(coroutine_kill(), pid or FFPLAY_FILENAME)
end

Audio.file_status = function(play_file_id)
	return played_files[play_file_id] and played_files[play_file_id].status
end

Audio.file_pid = function(play_file_id)
	return played_files[play_file_id] and played_files[play_file_id].pid
end

Audio.is_file_playing = function(play_file_id)
	-- local pid = play_file_id and played_files[play_file_id] and played_files[play_file_id].pid

	-- if not pid then
	-- 	return nil
	-- end

	-- return LocalServer.is_pid_running(pid)
	return
end

Audio.on_all_mods_loaded = function()
	LocalServer = get_mod("DarktideLocalServer")

	if not LocalServer then
		Audio:echo(
			'Required mod "Darktide Local Server" not found: Download from Nexus Mods and make sure it is in your mod_load_order.txt'
		)
		Audio:disable_all_hooks()
		Audio:disable_all_commands()
	end

	-- get_mod("Tests").run(Audio) -- Uncomment to run tests in 'watch mode'
end

Audio.settings_changed_functions["play_file"] = function(setting_name)
	if setting_name == "log_errors" then
		log_errors = Audio:get("log_errors")
	end
end