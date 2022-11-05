--#region importing libraries

import "Corelibs/object"
import "Corelibs/graphics"
import "Corelibs/sprites"
import "Corelibs/timer"
import "Corelibs/ui"
import "Corelibs/math"
import "Corelibs/crank"
import "Corelibs/keyboard"

import "Corelibs/utilities/sampler"-- this should go before final version

--#endregion


--#region shorthands

local pd <const> = playdate
local gfx <const> = pd.graphics
local geo <const> = pd.geometry
local snd <const> = pd.sound

local black <const> = gfx.kColorBlack
local white <const> = gfx.kColorWhite
local clear <const> = gfx.kColorClear
local lerp <const> = pd.math.lerp

--#endregion


--#region performance critical parameter declarations

local rendersize <const> = geo.vector2D.new(400,240)/2
local starting_playfield <const> = geo.point.new(100, 100)
local playfield = starting_playfield:copy()

-- bigger table slices = handling more unnecessary memory but also requires less separate draw calls
-- check for optimal size with new zoom
table_slice = 100

local render_zoom = 0.5 -- affects size of texture composed and perspective rendered every frame
local game_render = gfx.image.new(rendersize.x, rendersize.y) -- resulting size of perspectived render
local render_area = rendersize.x * 1.5 * render_zoom -- 1.5 approximates sqrt2 for diagonals of square to be visible 
local composite_image = gfx.image.new(render_area, render_area)

-- lower = less time spent drawing temporary lines to screen
-- going too low makes you collide with your present self
local collision_delay = 3

local trail_size = 4 -- radius of the trail drawn
local place_point_distance = 3
-- prevents lines from being cut off between slices/across edges
local drawmargin = trail_size+1

--#endregion


--#region wrap index for table

function wrap_index_for_table(_index, __table)
	return 1+ ((_index - 1) % #__table)
end

function wrap_pos_in_playfield(_pos)
	_pos.x = ((_pos.x + playfield.x/2)%playfield.x) - playfield.x/2
	_pos.y = ((_pos.y + playfield.y/2)%playfield.y) - playfield.y/2
end

function wrap_pos_in_offset_playfield(_pos, _offset)
	_pos.x = ((_pos.x + playfield.x/2 + _offset.x)%playfield.x) - playfield.x/2 -_offset.x
	_pos.y = ((_pos.y + playfield.y/2 + _offset.y)%playfield.y) - playfield.y/2 -_offset.y
end

--#endregion


--#region options and preferences

local default_preferences = {
	[1] = {
		name = "dpad turn speed",
		index = 3,
		options = {"0.25", "0.5", "1.0", "2.0", "4.0"},
		value = "1.0",
	},
	[2] = {
		name = "dpad turn boost",
		index = 3,
		options = {"0.5", "2.0", "3.0", "4.0", "5.0", "10.0"},
		value = "3.0",
	},
	[3] = {
		name = "move speed",
		index = 3,
		options = {"0.5", "0.75", "1.0", "1.25", "1.5", "2.0"},
		value = "1.0",
	},
	[4] = {
		name = "dpad discreet turns",
		index = 1,
		options = {"off", "4.0", "5.0", "6.0","7.0", "8.0"},
		value = "off",
	},
}

local preferences_table = table.deepcopy(default_preferences)

function load_preferences()
	local _loaded = pd.datastore.read("preferences")
	if _loaded == nil then
		preferences_table = table.deepcopy(default_preferences)
	else
		preferences_table = _loaded
	end
	
	save_preferences()
end

function save_preferences()
	pd.datastore.write(preferences_table, "preferences")
end

load_preferences()

local option_index = 1
local option_crank_ticks = 6
function options_inputs()
		
	local _change_index_by = 0
	if pd.buttonJustPressed(pd.kButtonUp) then _change_index_by -= 1 end
	if pd.buttonJustPressed(pd.kButtonDown) then _change_index_by += 1 end
	if pd.getCrankTicks(option_crank_ticks) ~= nil then _change_index_by += pd.getCrankTicks(option_crank_ticks) end

	option_index += _change_index_by
	option_index = wrap_index_for_table(option_index, preferences_table)

	local _change_option_by = 0
	if pd.buttonJustPressed(pd.kButtonRight) then _change_option_by += 1 end
	if pd.buttonJustPressed(pd.kButtonLeft) then _change_option_by -= 1 end
	
	if _change_option_by ~= 0 then
		for k, v in pairs(preferences_table) do
			if option_index == k then 

				v.index = tonumber(v.index) + _change_option_by

				v.index = wrap_index_for_table(v.index, default_preferences[k].options)
				v.value = default_preferences[k].options[v.index]
				save_preferences()
			end
		end
	end
end

local mono_font = gfx.font.new("font/Roobert-11-Mono-Condensed")
function options_display()
	gfx.setFont(mono_font)

	gfx.drawText("(b) to go to menu", 10, 10)
	local _i = 0
	
	for k, v in pairs(preferences_table) do
		_i += 1
		local _text_line = " " -- option not chosen prefix
		if option_index == k then _text_line = ">" end -- option chosen prefix

		_text_line = _text_line..string.format("% 5s", tostring(v.value)).."|"..v.name
		gfx.drawText(_text_line, 5,20 + _i*15)
	end
end

--#endregion


--#region player, camera and portal parameters

-- these next few affect base difficulty, which is modified by preferences
local move_speed = 3.0 * render_zoom
local turn_speed = math.pi * 2.0 -- currently 1 to 1 crank to angle

-- # of points until next portal per layer. 
-- when it reaches the end it doesn't spawn any more of them
-- i sorsta pulled the numbers out my ass but they sorta work,
-- tweak them if you think that'd be better
local zoomportal_score_thresholds = {
	[1] = 8,
	[2] = 30,
	[3] = 100,
	[4] = 300,
	-- [5] = ,
}

local default_player = {
	x = playfield.x/2,
	y = playfield.y/2,
	angle = math.pi,
	layer = false,
	primed = false,
	alive = true,
	score = 0,
	will_swap = false,
}
local player = table.shallowcopy(default_player)

local lookahead = 15 -- how far the point camera follows is in front of the player, 0 places player at center of screen, 20+ almost offscreen
local default_camera = {
	off_x = math.sin(player.angle)*lookahead,
	off_y = math.cos(player.angle)*lookahead,
	speed_x = 0,
	speed_y = 0,
	angle = player.angle,
	tilt = 30,
	tilt_speed = 0,
	pz = 150,
	pz_speed = 0,
	shake_amp = 0,
}
local camera = table.shallowcopy(default_camera)

local deaful_zoomportal = {
	x = 0,
	y = 0,
	enabled = false,
	last_threshold = 1,
	score_till_next = zoomportal_score_thresholds[1],
}
local zoomportal = table.shallowcopy(deaful_zoomportal)

--#endregion


--#region playing sounds

local hip = snd.sampleplayer.new("sounds/hip.wav")
local hop = snd.sampleplayer.new("sounds/hop.wav")
local click = snd.sampleplayer.new("sounds/click.wav")
local clack = snd.sampleplayer.new("sounds/tock.wav")
local death = snd.sampleplayer.new("sounds/deth.wav")
local portalenter = snd.sampleplayer.new("sounds/wzhuup.wav")
local portalspawn = snd.sampleplayer.new("sounds/bwaaam.wav")

function sfx_menu_next()
	click:play(1)
end

function sfx_menu_back()
	clack:play(1)
end

function sfx_cross_trail()
	if player.layer then
		hip:play(1)
	else
		hop:play(1)
	end
end

function sfx_death()
	death:play(1)
end

function sfx_portal_spawn()
	portalspawn:play(1)
end

function sfx_portal_enter()
	portalenter:play(1)
end

function sfx_start_game()
	portalenter:play(1)
end

--#endregion

--#region draw elements

function draw_player(_in_rect)
	local _screenpoint = geo.point.new(player.x - _in_rect.left, player.y - _in_rect.top)

	if player.alive then
		
		-- draw the point that points in the direction of the portal
		if zoomportal.enabled then
			local _to_portal = geo.vector2D.new(zoomportal.x - player.x, zoomportal.y - player.y)
			wrap_pos_in_playfield(_to_portal)

			gfx.setColor(black)
			gfx.fillCircleAtPoint(_screenpoint + _to_portal:normalized()*6, 1)
		end
		
		if player.primed then
			-- alive and primed
			gfx.setColor(black)
			gfx.fillCircleAtPoint(_screenpoint, 4)
			gfx.setColor(white)
			gfx.fillCircleAtPoint(_screenpoint, 2)
		else
			-- alive and not primed
			gfx.setColor(black)
			gfx.fillCircleAtPoint(_screenpoint, 4)
		end
	else
		-- dead, draw a cross
		local _dist = 5
		local _angle = player.angle + math.pi/4
		local _fr = _screenpoint:offsetBy(math.sin(_angle)*_dist, math.cos(_angle)*_dist)
		_angle += math.pi/2
		local _br = _screenpoint:offsetBy(math.sin(_angle)*_dist, math.cos(_angle)*_dist)
		_angle += math.pi/2
		local _bl = _screenpoint:offsetBy(math.sin(_angle)*_dist, math.cos(_angle)*_dist)
		_angle += math.pi/2
		local _fl = _screenpoint:offsetBy(math.sin(_angle)*_dist, math.cos(_angle)*_dist)
		
		gfx.setLineWidth(7)
		gfx.setLineCapStyle(gfx.kLineCapStyleSquare)
		gfx.setColor(black)
		gfx.drawLine(_fr.x, _fr.y, _bl.x, _bl.y)
		gfx.drawLine(_br.x, _br.y, _fl.x, _fl.y)
		
		gfx.setLineWidth(3)
		gfx.setLineCapStyle(gfx.kLineCapStyleSquare)
		gfx.setColor(white)
		gfx.drawLine(_fr.x, _fr.y, _bl.x, _bl.y)
		gfx.drawLine(_br.x, _br.y, _fl.x, _fl.y)
		
	end
	
end

function draw_portal_at_screen_point(_screenpoint)
	gfx.setColor(black)
	gfx.fillRect(_screenpoint.x - 5, _screenpoint.y - 5, 10, 10)
	gfx.setColor(white)
	gfx.fillRect(_screenpoint.x - 3, _screenpoint.y - 3, 6, 6)
	gfx.setColor(black)
	gfx.fillRect(_screenpoint.x - 1, _screenpoint.y - 1, 2, 2)
end


local portal_drawmargin = 20
function draw_portal(_in_rect)
	if zoomportal.enabled then
		local _screenpoint = geo.point.new(zoomportal.x, zoomportal.y)
		wrap_pos_in_playfield(_screenpoint)
		
		_screenpoint.x -= _in_rect.left
		_screenpoint.y -= _in_rect.top
		
		local _instances_drawn = 0
		for x=-1, 1 do
			for y=-1, 1 do
				local _offset_point = _screenpoint:offsetBy(playfield.x*x, playfield.y*y)
				if _offset_point.x > -portal_drawmargin and _offset_point.x < playfield.x + portal_drawmargin and _offset_point.y > -portal_drawmargin and _offset_point.y < playfield.y + portal_drawmargin then
					draw_portal_at_screen_point(_offset_point)
					_instances_drawn += 1
				end
			end
		end
	end
	
end


function consider_placing_a_portal()
	if not zoomportal.enabled then
			-- not yet out of bounds
		if zoomportal.score_till_next <= 0 and zoomportal.last_threshold + 1 <= #zoomportal_score_thresholds then
			
			-- zoomportal.last_threshold = _new_threshold
			
			-- this is done to prevent placing a portal on top of a line, doesn't usually need more than one iteration
			local _good_position = false
			local iter = 0
			while iter < 10 and not _good_position do
				iter += 1
				local _random_angle = math.random() * math.pi
				local _relative_to_player = geo.vector2D.new(player.x + math.sin(_random_angle) * playfield.x/2, player.y + math.cos(_random_angle) * playfield.y/2) -- haha, still pretending like playfield isnt a fucking square lol, tho idk, i think it would be kinda funny to add weird tiling/stretcing types of playfield upscaling
				zoomportal.x = _relative_to_player.x % playfield.x
				zoomportal.y = _relative_to_player.y % playfield.y
				
				local _l_0 = layer_0_in_table[pos_to_table_index(zoomportal.x)][pos_to_table_index(zoomportal.y)]
				local _l_1 = layer_1_in_table[pos_to_table_index(zoomportal.x)][pos_to_table_index(zoomportal.y)]
				
				local _l_0_c = _l_0:sample(zoomportal.x % table_slice, zoomportal.y % table_slice) ~= black
				local _l_1_c = _l_1:sample(zoomportal.x % table_slice, zoomportal.y % table_slice) ~= black

				_good_position = (_l_0_c and _l_1_c)
			end
			
			if _good_position then
				print("placed portal after "..tostring(iter).." tries")
				zoomportal.enabled = true
				sfx_portal_spawn()
			end
		end
	end -- dont think if its already up
end

local portal_collision_radius = 7
function consider_collecting_a_portal()
	if zoomportal.enabled then
		local _relative = geo.vector2D.new(zoomportal.x - player.x, zoomportal.y - player.y)
		wrap_pos_in_playfield(_relative)
		
		if _relative:magnitude() < portal_collision_radius then
			double_playfield()
			local _new_threshold = zoomportal.last_threshold + 1
			
			zoomportal.score_till_next = zoomportal_score_thresholds[_new_threshold]
			zoomportal.last_threshold = _new_threshold
			zoomportal.enabled = false
			sfx_portal_enter()
		end
	end
	
end

--#endregion


--#region point handling

local points = {}
local points_layer = {}

-- regularly leave points at current position
-- only used to redraw a scaled image later down the line 
-- and to draw the last few points in the trail that haven't been drawn to texture yet
function save_trail_point()
	local path_point = geo.point.new(player.x, player.y)
	points[#points+1] = path_point
	points_layer[#points_layer+1] = player.layer
	draw_past_trail()
end

function consider_placing_a_point()
	if #points > 0 then
		local _last_point = points[#points]
		local distance_to_last = geo.vector2D.new(_last_point.x - player.x, _last_point.y - player.y)
		wrap_pos_in_playfield(distance_to_last)

		if distance_to_last:magnitude() > place_point_distance then
			save_trail_point()
		end
	else
		save_trail_point()
	end
end

--#endregion


--#region game setup

local function begin_game()
	pd.ui.crankIndicator:start()
	
	points = {}
	points_layer = {}
	
	playfield = starting_playfield:copy()
	
	player = table.shallowcopy(default_player)
	camera = table.shallowcopy(default_camera)
	zoomportal = table.shallowcopy(deaful_zoomportal)
	
	layer_0_in_table = {}
	layer_1_in_table = {}
	prepare_table_for_playfield(layer_0_in_table)
	prepare_table_for_playfield(layer_1_in_table)
end

--#endregion


--#region image table handling

layer_0_in_table = {}
layer_1_in_table = {}

-- not used often enough
function pos_to_table_index(_pos)
	return math.ceil(_pos / table_slice)
end

clear_slice = gfx.image.new(table_slice, table_slice, clear)
function prepare_table_for_playfield(_table)
	for x = 1, pos_to_table_index(playfield.x) do
		_table[x] = {}
		for y = 1, pos_to_table_index(playfield.y) do
			_table[x][y] = clear_slice:copy()
		end
	end
end

--#endregion


--#region camera motion

local function animate_camera()
	
	local targetoff = nil
	if player.alive then targetoff = lookahead else targetoff = 0 end
	
	local target_x = math.sin(player.angle) * targetoff
	local target_y = math.cos(player.angle) * targetoff
	
	camera.speed_x = lerp(camera.speed_x, (target_x - camera.off_x)*0.5, 0.5)
	camera.speed_y = lerp(camera.speed_y, (target_y - camera.off_y)*0.5, 0.5)
	
	camera.off_x += camera.speed_x
	camera.off_y += camera.speed_y
	camera.off_x += (math.random() - 0.5) * camera.shake_amp
	camera.off_y += (math.random() - 0.5) * camera.shake_amp
	
	camera.shake_amp = math.max(0, camera.shake_amp - 1)
	
	local angle_diff = player.angle - camera.angle
	angle_diff = (angle_diff + math.pi)%(math.pi * 2) - math.pi
	
	camera.angle += angle_diff * 0.25
	
	local target_tilt = 30
	camera.tilt_speed = lerp(camera.tilt_speed, (target_tilt - camera.tilt)*0.5, 0.25)
	camera.tilt += camera.tilt_speed
	
	local target_pz = 150
	camera.pz_speed = lerp(camera.pz_speed, (target_pz-camera.pz) * 0.75, 0.125)
	camera.pz += camera.pz_speed
	
end

-- this function is called when you cross your own path
local function bump_camera()
	camera.speed_x += math.sin(player.angle) * 5
	camera.speed_y += math.cos(player.angle) * 5
	camera.tilt_speed += 1.5
	camera.pz_speed -= 10
end

local function crash_camera()
	camera.shake_amp = 10
end

--#endregion


--#region gameplay, idk

local dpad_turn_speed = 0.075

local secret_other_condition = false

local function move_player()

	if pd.isCrankDocked() then
		if preferences_table[4].value == "off" then
			-- crank is docked and discrete turning is off, turn smoothly
			local _turnspeed_mp = tonumber(preferences_table[1].value)
			local turn_acceleration = 1.0
			if pd.buttonIsPressed(pd.kButtonA) then
				turn_acceleration = tonumber(preferences_table[2].value)
			end
			if pd.buttonIsPressed(pd.kButtonRight) then
				player.angle -= dpad_turn_speed * turn_acceleration * _turnspeed_mp
			end
			if pd.buttonIsPressed(pd.kButtonLeft) then
				player.angle += dpad_turn_speed * turn_acceleration * _turnspeed_mp
			end
		else
			-- discrete turning enabled and active
			local _fractions = tonumber(preferences_table[4].value)
			if pd.buttonJustPressed(pd.kButtonRight) then
				player.angle -= 2*math.pi/_fractions
				save_trail_point() -- add point in path for sharper crease when turning
			end
			if pd.buttonJustPressed(pd.kButtonLeft) then
				player.angle += 2*math.pi/_fractions
				save_trail_point()
			end
			
		end
	else
		-- normally just turn using a crank
		player.angle += turn_speed * pd.getCrankChange() / 360
	end
	
	local _speed_mp = tonumber(preferences_table[3].value)
	
	-- move forward
	player.x += math.sin(player.angle) * move_speed * _speed_mp
	player.y += math.cos(player.angle) * move_speed * _speed_mp
	
	player.x %= playfield.x
	player.y %= playfield.y
	
	camera.off_x += math.sin(player.angle) * move_speed * _speed_mp
	camera.off_y += math.cos(player.angle) * move_speed * _speed_mp
end

function playing_state_inputs()
	if pd.buttonJustPressed(pd.kButtonB) or pd.buttonJustPressed(pd.kButtonDown) or pd.buttonJustPressed(pd.kButtonUp) then
		player.will_swap = true
	end
end

local last_collide_with
local last_collision_player_pos
function collide_and_swap_layer()
	local collidewith = nil
	local scorewith = nil

	local ptx = wrap_index_for_table(pos_to_table_index(player.x), layer_0_in_table)
	local pty = wrap_index_for_table(pos_to_table_index(player.y), layer_0_in_table[1])
	
	if player.layer then
		collidewith = layer_1_in_table[ptx][pty]
		scorewith = layer_0_in_table[ptx][pty]
	else
		collidewith = layer_0_in_table[ptx][pty]
		scorewith = layer_1_in_table[ptx][pty]
	end
	
	local wrapped_player_pos = geo.vector2D.new(player.x - (pos_to_table_index(player.x)-1) * table_slice, player.y - (pos_to_table_index(player.y)-1) * table_slice)
	last_collide_with = collidewith
	last_collision_player_pos = wrapped_player_pos
	
	
	if collidewith:sample(wrapped_player_pos.x, wrapped_player_pos.y) == black and player.alive then
		player.alive = false
		sfx_death()
		crash_camera()
	end
	if scorewith:sample(wrapped_player_pos.x, wrapped_player_pos.y) == black and player.alive and player.primed then
		player.primed = false
		player.score += 1
		zoomportal.score_till_next -= 1
		sfx_cross_trail()
		bump_camera()
	end
	
	local on_top_of_trail = scorewith:sample(wrapped_player_pos.x, wrapped_player_pos.y) == black
	
	if player.will_swap and (not on_top_of_trail) then
		player.will_swap = false
		player.layer = not player.layer
		player.primed = not player.primed
	end
end

--#endregion


--#region game rendering functions

function draw_past_trail()
	if #points > collision_delay then
		local last_point = points[#points - collision_delay]:copy()
		local new_layer = points_layer[#points - collision_delay + 1]
		local new_point = points[#points - collision_delay + 1]:copy()
		
		wrap_pos_in_offset_playfield(last_point, geo.point.new(-new_point.x, -new_point.y))
		
		gfx.setLineWidth(trail_size)
		gfx.setColor(black)
		gfx.setLineCapStyle(gfx.kLineCapStyleRound)
		
		-- choose which rects to draw to
		-- first calculate info about current rect
		local target_rects = {}
		local current_rect = geo.vector2D.new(pos_to_table_index(new_point.x), pos_to_table_index(new_point.y))
		target_rects[1] = current_rect
		
		local rect_offset = (current_rect + geo.vector2D.new(-1,-1)) * table_slice
		
		local new_relative = new_point:offsetBy(-rect_offset.x , -rect_offset.y)
		local last_relative = last_point:offsetBy(-rect_offset.x, -rect_offset.y)
		
		-- add neighbours if fit criteria
		local _left = new_relative.x < drawmargin or last_relative.x < drawmargin
		local _right = new_relative.x > table_slice - drawmargin or last_relative.x > table_slice - drawmargin
		local _top = new_relative.y < drawmargin or last_relative.y < drawmargin
		local _bottom = new_relative.y > table_slice - drawmargin or last_relative.y > table_slice - drawmargin
		
		if _left then
			target_rects[#target_rects+1] = geo.vector2D.new(current_rect.x-1, current_rect.y)
		end
		if _right then
			target_rects[#target_rects+1] = geo.vector2D.new(current_rect.x+1, current_rect.y)
		end
		
		if _top then
			target_rects[#target_rects+1] = geo.vector2D.new(current_rect.x, current_rect.y-1)
		end
		if _bottom then
			target_rects[#target_rects+1] = geo.vector2D.new(current_rect.x, current_rect.y+1)
		end
		
		if _left and _top then
			target_rects[#target_rects+1] = geo.vector2D.new(current_rect.x-1, current_rect.y-1)
		end
		if _right and _top then
			target_rects[#target_rects+1] = geo.vector2D.new(current_rect.x+1, current_rect.y-1)
		end
		if _left and _bottom then
			target_rects[#target_rects+1] = geo.vector2D.new(current_rect.x-1, current_rect.y+1)
		end
		if _right and _bottom then
			target_rects[#target_rects+1] = geo.vector2D.new(current_rect.x+1, current_rect.y+1)
		end
		
		local target_layer = nil
		
		if new_layer then target_layer = layer_1_in_table else target_layer = layer_0_in_table end
		local tablesize_x = #target_layer
		local tablesize_y = #target_layer[1]
		
		for i=1, #target_rects do
			local target = target_rects[i]
			rect_offset = (target + geo.vector2D.new(-1,-1)) * table_slice
			target.x = wrap_index_for_table(target.x, target_layer)
			target.y = wrap_index_for_table(target.y, target_layer[1])
			
			gfx.lockFocus(target_layer[target.x][target.y])
				gfx.drawLine(last_point.x - rect_offset.x, last_point.y - rect_offset.y, new_point.x - rect_offset.x, new_point.y - rect_offset.y)
			gfx.unlockFocus()
		end
	end
end

function render_layer(layer)
	gfx.setLineWidth(trail_size)
	gfx.setColor(black)
	gfx.setLineCapStyle(gfx.kLineCapStyleRound)
	
	local layer_render = gfx.image.new(playfield.x, playfield.y)
	gfx.lockFocus(layer_render)
	-- check just to be sure and not crash, should not encounter when playing normally
	if #points >= 2 then
		for i = 1, math.max(#points - collision_delay + 1, 1) do
			-- iterate through all points except the last collision delayed ones
			
			local next_layer = points_layer[i+1]
			if next_layer == layer then
				
				local next_point = points[i+1]:copy()
				local prev_point = points[i]:copy()
				
				wrap_pos_in_offset_playfield(prev_point, geo.point.new(-next_point.x, -next_point.y))
				
				local offsets = {}
				offsets[1] = geo.vector2D.new(0,0)
				
				local _left = prev_point.x < drawmargin or next_point.x < drawmargin 
				local _right = prev_point.x > playfield.x - drawmargin or next_point.x > playfield.x - drawmargin
				local _top = prev_point.y < drawmargin or next_point.y < drawmargin
				local _bottom = prev_point.y > playfield.y - drawmargin or next_point.y > playfield.y - drawmargin
				
				if _left then
					offsets[#offsets+1] = geo.vector2D.new(playfield.x, 0)
				end
				if _right then
					offsets[#offsets+1] = geo.vector2D.new(-playfield.x, 0)
				end
				
				if _top then
					offsets[#offsets+1] = geo.vector2D.new(0, playfield.y)
				end
				if _bottom then
					offsets[#offsets+1] = geo.vector2D.new(0, -playfield.y)
				end
				
				if _left and _top then
					offsets[#offsets+1] = geo.vector2D.new(playfield.x, playfield.y)
				end
				if _left and _bottom then
					-- based
					offsets[#offsets+1] = geo.vector2D.new(playfield.x, -playfield.y)
				end
				if _right and _top then
					offsets[#offsets+1] = geo.vector2D.new(-playfield.x, playfield.y)
				end
				if _right and _bottom then
					offsets[#offsets+1] = geo.vector2D.new(-playfield.x, -playfield.y)
				end
				
				for i, offset in pairs(offsets) do
					gfx.drawLine(prev_point.x + offset.x, prev_point.y + offset.y, next_point.x + offset.x, next_point.y + offset.y)
				end
			end
		end
	end
	gfx.unlockFocus()
	return layer_render
end

function render_layer_tables()
	local layer_0_render = render_layer(false)
	local layer_1_render = render_layer(true)
	
	prepare_table_for_playfield(layer_0_in_table)
	prepare_table_for_playfield(layer_1_in_table)
	
	gfx.setClipRect(0,0, table_slice, table_slice)
	
	for x = 1, #layer_0_in_table do
		for y = 1, #layer_0_in_table[1] do
			gfx.lockFocus(layer_0_in_table[x][y])
				layer_0_render:draw((-x+1) * table_slice, (-y+1) * table_slice)
			gfx.unlockFocus()
		end
	end
	
	for x = 1, #layer_1_in_table do
		for y = 1, #layer_1_in_table[1] do
			gfx.lockFocus(layer_1_in_table[x][y])
				layer_1_render:draw((-x+1) * table_slice, (-y+1) * table_slice)
			gfx.unlockFocus()
		end
	end
	
	gfx.clearClipRect()
	
end

function double_playfield()
	player.x *= 2
	player.y *= 2
	
	playfield.x = playfield.x * 2
	playfield.y = playfield.y * 2
	
	for i=1, #points do
		points[i].x *= 2
		points[i].y *= 2
	end
	
	render_layer_tables()
end

function draw_recent_line(on_which_layer, render_off)
	-- sample("draw recent", function ()
	gfx.setLineWidth(trail_size)
	gfx.setLineCapStyle(gfx.kLineCapStyleRound)
	local player_off = geo.vector2D.new(-player.x, -player.y)
	-- draw previous points in line that are not yet on collision for foreground
	if #points >= 2 then
		for i = math.max(#points - collision_delay + 1, 1), #points-1 do
			
			local next_layer = points_layer[i+1]
			if next_layer == on_which_layer then
				local next_point = points[i+1]:copy()
				local prev_point = points[i]:copy()
				
				wrap_pos_in_offset_playfield(prev_point, player_off)
				wrap_pos_in_offset_playfield(next_point, player_off)
				
				gfx.drawLine(prev_point.x - render_off.x, prev_point.y - render_off.y, next_point.x - render_off.x, next_point.y - render_off.y)
			end
		end
	end
	
	-- then connect it to the player
	if #points >= 1 then
		local prev_point = points[#points]:copy()
		local next_point = geo.point.new(player.x, player.y)
		
		wrap_pos_in_offset_playfield(prev_point, player_off)
		wrap_pos_in_offset_playfield(next_point, player_off)
		
		gfx.drawLine(prev_point.x - render_off.x, prev_point.y - render_off.y, next_point.x - render_off.x, next_point.y - render_off.y)
	end
	-- end)
end

function draw_layertable_for_rect(layertable, _rect)
	-- sample("draw layertable", function ()
	for x = math.floor(_rect.left/table_slice), math.ceil(_rect.right/table_slice) do
		for y = math.floor(_rect.top/table_slice), math.ceil(_rect.bottom/table_slice) do
			layertable[wrap_index_for_table(x, layertable)][wrap_index_for_table(y, layertable[1])]:draw( math.floor((x-1)*table_slice - _rect.left), math.floor((y-1)*table_slice - _rect.top))
		end
	end
	-- end)
end

function render_in_perspective()
	gfx.lockFocus(game_render)
		gfx.clear(clear)
		
		gfx.setImageDrawMode(gfx.kDrawModeCopy)
		
		-- to do change these on the fly for extra funk and edge fuzz
		local pa = -camera.angle + math.pi
		local perspective_z = camera.pz
		local tilt_angle = camera.tilt
		local sc = render_zoom -- zoom scale of perspective renderer
		
		composite_image:drawSampled(0,0, -- coordinates of top left corner
				game_render.width, game_render.height, -- drawrects width and height
				0.5, 0.5, -- origin for matrix transform
				math.cos(pa) * sc, math.sin(pa) * sc, -math.sin(pa) * sc, math.cos(pa) * sc, -- transformation matrix for rotating it around centre
				0.5, 0.5, --offset
				perspective_z, tilt_angle, false)
	gfx.unlockFocus()
	
end

-- not currently called
-- leftover from debug draw
-- might be good for displaying end of game results if the final screen is huuuge
function render_layers_to_screen()
	
	gfx.setImageDrawMode(gfx.kDrawModeInverted)
	for x = 1, #layer_0_in_table do
		for y = 1, #layer_0_in_table[1] do
			layer_0_in_table[x][y]:draw((x-1) * table_slice, (y-1) * table_slice)
		end
	end
	
	gfx.setImageDrawMode(gfx.kDrawModeCopy)
	for x = 1, #layer_1_in_table do
		for y = 1, #layer_1_in_table[1] do
			layer_1_in_table[x][y]:draw((x-1) * table_slice, (y-1) * table_slice)
		end
	end
end

function display_render()
	gfx.clear(white)
	gfx.setColor(black)
	gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
	gfx.fillRect(0,0, 400, 240)
	
	game_render:draw(0,0)
end

function compose_image()
	gfx.lockFocus(composite_image)
		gfx.clear(clear)
		
		local render_in_rect = geo.rect.new(camera.off_x + player.x - render_area/2, camera.off_y + player.y - render_area/2, render_area, render_area)
		
		local lower_layer = nil
		local upper_layer = nil
		
		if player.layer then
			upper_layer = layer_1_in_table
			lower_layer = layer_0_in_table
		else
			upper_layer = layer_0_in_table
			lower_layer = layer_1_in_table
		end
		-- sample("compose lower		", function()
		gfx.setImageDrawMode(gfx.kDrawModeInverted)
		draw_layertable_for_rect(lower_layer, render_in_rect)
		-- end)
		
		-- sample("draw new lower		", function()
		gfx.setColor(white)
		draw_recent_line(not player.layer, geo.vector2D.new(render_in_rect.left, render_in_rect.top))
		-- end)
		
		-- sample("compose upper		", function()
		gfx.setImageDrawMode(gfx.kDrawModeCopy)
		draw_layertable_for_rect(upper_layer, render_in_rect)
		-- end)
		
		-- sample("draw new upper		", function()
		gfx.setColor(black)
		draw_recent_line(player.layer, geo.vector2D.new(render_in_rect.left, render_in_rect.top))
		-- end)
		
		-- sample("draw characters", function ()
		draw_portal(render_in_rect)
		draw_player(render_in_rect)
		-- end)
		
	gfx.unlockFocus()
end


local scorefont = gfx.font.new("font/Asheville-Sans-14-Bold")
function draw_score()
	gfx.setFont(scorefont)
	gfx.setColor(white)
	gfx.fillRect(0,0, 60, 30)
	gfx.drawText("scr:"..tostring(player.score),0,0)
	if not zoomportal.enabled then
		gfx.drawText("zpin:"..tostring(math.max(zoomportal.score_till_next,0)),0,14)
	else
		gfx.drawText("zmprtlrdy",0,14)
	end
	
	
end

function draw_collision_debug()
	gfx.setColor(black)
	gfx.fillRect(4,4, table_slice + 4, table_slice + 4)
	gfx.setColor(white)
	gfx.fillRect(6,6, table_slice, table_slice)
	
	if last_collide_with ~= nil then
		last_collide_with:draw(6,6)
	end
	
	gfx.setColor(black)
	gfx.fillCircleAtPoint(last_collision_player_pos.x + 6, last_collision_player_pos.y + 6, 2)
	
	gfx.setColor(white)
	gfx.fillCircleAtPoint(last_collision_player_pos.x + 6, last_collision_player_pos.y + 6, 1)
end

--#endregion


--#region scrolling image

local scroll_offset = geo.vector2D.new(0,0)
local scrolling_image = nil

function render_sexy_scrolling_image()
	scrolling_image = gfx.image.new(playfield.x, playfield.y, clear)
	gfx.pushContext(scrolling_image)
	
		local lower = render_layer(false)
		local upper = render_layer(true)
		
		local lower_faded = lower:fadedImage(0.75, gfx.image.kDitherTypeScreen)
		local upper_faded = upper:fadedImage(0.5, gfx.image.kDitherTypeScreen)

		gfx.setImageDrawMode(gfx.kDrawModeCopy)
		lower_faded:draw(0,0)
		
		-- draw top outline
		gfx.setImageDrawMode(gfx.kDrawModeInverted)
		upper_faded:draw(2,-2)
		upper_faded:draw(2,0)
		upper_faded:draw(2,2)
		upper_faded:draw(0,-2)
		upper_faded:draw(0,2)
		upper_faded:draw(-2,-2)
		upper_faded:draw(-2,0)
		upper_faded:draw(-2,2)
		
		-- draw top
		gfx.setImageDrawMode(gfx.kDrawModeCopy)
		upper:draw(0,0)

	gfx.popContext()
end


function update_image_scroll_offset()
	scroll_offset += geo.vector2D.new(1, 100/scrolling_image.height) * 2
	scroll_offset.x %= scrolling_image.width
	scroll_offset.y %= scrolling_image.height
end

-- to do: add option to slide across image manually for gallery_display ?

function draw_scrolling_image()
	
	if scroolimg_render_type_overunder then
		gfx.setColor(white)
		gfx.fillRect(0,0, 400, 240)
	else
		gfx.setColor(black)
		gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
	end

	for x = 0, math.ceil(400/scrolling_image.width) do
		for y = 0, math.ceil(240/scrolling_image.height) do
			scrolling_image:draw(scroll_offset.x + (x-1)*scrolling_image.width, scroll_offset.y + (y-1)*scrolling_image.height)
		end
	end

end

--#endregion


--#region gallery interface

local name_adjectives = {
	"sexy",
	"tangled",
	"weaved",
	"tight",
}

local name_nouns = {
	"line",
	"circuit",
	"road",
	"worm",
	"trail",
	"anthill"
	
}

-- when saving an image it picks a random name, make these as big as you want, i think it'll be funny to see what it can generate
function generate_name()
	local _new_name = "piss"
	_new_name = name_adjectives[math.random(1, #name_adjectives)].." "..name_nouns[math.random(1, #name_nouns)]

	return _new_name
end

function save_scrolling_image_to_gallery()
	local _time = pd.getTime()
	local _writetime = pd.getSecondsSinceEpoch()
	local gallery_save = {
		name = generate_name(),
		date = _writetime,
		score = player.score,
		image_path = "image/"..tostring(_writetime),  -- dumbass way to name them but shouldnt repeat filenames lol
		self_path = "gallery/"..tostring(_writetime),
	}
	pd.datastore.write(gallery_save, gallery_save.self_path)
	pd.datastore.writeImage(scrolling_image, gallery_save.image_path)
	
end

function load_scrolling_image_from_gallery_save(_gallery_save)
	scrolling_image = pd.datastore.readImage(_gallery_save.image_path)
end


local current_gallery_index = 1 -- for choosing, int
local gallery_crank_ticks = 6

local gallery_saves_table = {}
local current_gallery_offset = 0 -- for pretty visuals later, float offset

function load_gallery_saves()
	gallery_saves_table = {}
	local _gallery_list = pd.file.listFiles("gallery/")
	if _gallery_list ~= nil then
		for i, path in pairs(pd.file.listFiles("gallery/")) do
			local target_path = "gallery/"..path
			target_path = target_path:gsub("%.json", "")
			-- print(target_path)
			gallery_saves_table[#gallery_saves_table+1] = pd.datastore.read(target_path)
		end
	end
end

function delete_gallery_save(index)
	local _result_1 = pd.datastore.delete(gallery_saves_table[index].self_path) -- false if could not be deleted
	local _result_2 = pd.datastore.delete(gallery_saves_table[index].image_path)
	table.remove(gallery_saves_table, current_gallery_index)
	
	-- the files do get deleted but im not sure why the gamedata size doesnt shrink significantly
end

function update_gallery_save(index)
	pd.datastore.write(gallery_saves_table[index], gallery_saves_table[index].self_path)
end


local deleting = false
local renaming = false
local prevname = ""
function gallery_scrolling()
	
	local crank_change = 0
	if pd.buttonJustPressed(pd.kButtonUp) then crank_change -= 1 end
	if pd.buttonJustPressed(pd.kButtonDown) then crank_change += 1 end
	crank_change += pd.getCrankTicks(gallery_crank_ticks)
	
	-- if things are normal - move
	if not renaming and not deleting then
		current_gallery_index += crank_change
		current_gallery_offset += crank_change
	end
	
	-- if not empty table
	if #gallery_saves_table > 0 then
		
		-- select current
		current_gallery_index = 1+ ((current_gallery_index-1)%#gallery_saves_table)
		
		-- if not doing things start renaming
		if pd.buttonJustPressed(pd.kButtonRight) and not renaming and not deleting then
			renaming = true
			prevname = gallery_saves_table[current_gallery_index].name
			pd.keyboard.show()
			pd.keyboard.text = prevname
		end
		
		-- if not doing things start deleting
		if pd.buttonJustPressed(pd.kButtonLeft) and not deleting and not renaming then
			deleting = true
		end
		
		if renaming then
			if not pd.keyboard.isVisible() then
				-- apply text when it hides
				renaming = false
				if gallery_saves_table[current_gallery_index].name == "" then gallery_saves_table[current_gallery_index].name = prevname end -- having a non name is forbidden, also i didn't give enough of a shit to do the keyboard callbacks
				update_gallery_save(current_gallery_index)
			else
				-- update text while kb is visible
				gallery_saves_table[current_gallery_index].name = pd.keyboard.text
			end
		end
		
		if deleting then
			if pd.buttonJustPressed(pd.kButtonB) then
				-- go through with deleting
				delete_gallery_save(current_gallery_index)
				deleting = false
			end
			if pd.buttonJustPressed(pd.kButtonA) then
				-- cancel
				deleting = false
			end
		end
	end
		
	current_gallery_offset = lerp(current_gallery_offset, 0, 0.25)
	
end


function display_gallery()
	gfx.setFont(mono_font)
	if #gallery_saves_table > 0 then
		for i= -2 - math.floor(current_gallery_offset+0.5), 2 - math.ceil(current_gallery_offset-0.5) do
			local wi = wrap_index_for_table(i + current_gallery_index, gallery_saves_table)--1 + ((i - 1 + current_gallery_index)%#gallery_saves_table)
			
			local _selected_time = pd.timeFromEpoch(gallery_saves_table[wi].date,0)
			local _date_text = string.format("%02d/%02d/%04d", _selected_time.day, _selected_time.month, _selected_time.year)
			local _time_text = string.format("%02d:%02d", _selected_time.hour, _selected_time.minute)
			local _display_text_l1 = gallery_saves_table[wi].name
			local _display_text_l2 = " scr:"..string.format("%04d", gallery_saves_table[wi].score).." at ".._time_text.." on ".._date_text
			
			if i == 0 then
				_display_text_l1 = ">".._display_text_l1
			else
				_display_text_l1 = " ".._display_text_l1
			end
			
			local _offset = i + current_gallery_offset
			gfx.drawText(_display_text_l1, 2, 150 + _offset*30)
			gfx.drawText(_display_text_l2, 8, 150 + _offset*30 + 13)
			
		end
		
		if deleting then
			-- display pop up for confirmation
			gfx.setColor(white)
			gfx.fillRect(100, 100, 200, 50)
			gfx.setColor(black)
			gfx.drawRect(100, 100, 200, 50)
			gfx.drawText("(b) to remove for good\n(a) to cancel",110,110)
		end
		
		
	end
	
end

--#endregion


--#region game intro onboarding

local steering_introduced = false
local layerswap_introduced = false
local dpad_l_introduced = false
local dpad_r_introduced = false
local turnacc_introduced = false

function onboarded()
	if pd.isCrankDocked() then
		return dpad_l_introduced and dpad_r_introduced and layerswap_introduced and turnacc_introduced
	else
		return steering_introduced and layerswap_introduced
	end
end

function display_onboarding()

	gfx.setDrawOffset(0,0)
	if pd.isCrankDocked() then
		if not dpad_l_introduced then
			if pd.buttonJustPressed(pd.kButtonLeft) then
				dpad_l_introduced = true
			end
			gfx.drawText("d left to steer", 10, 10)
		end
		
		if not dpad_r_introduced then
			if pd.buttonJustPressed(pd.kButtonRight) then
				dpad_r_introduced = true
			end
			gfx.drawText("d right to steer", 10, 25)
		end
		
		if not turnacc_introduced then
			if pd.buttonJustPressed(pd.kButtonA) then
				turnacc_introduced = true
			end
			gfx.drawText("a to turn faster", 10, 40)
		end

		gfx.drawText("undock to use crank", 10, 55)
	else
		if not steering_introduced then
			if pd.getCrankChange() ~= 0 then
				steering_introduced = true
			end
			gfx.drawText("crank to steer", 10, 10)
		end
		gfx.drawText("dock to use dpad", 10, 25)
	end
	
	
	if not layerswap_introduced then
		if pd.buttonJustPressed(pd.kButtonB) then
			layerswap_introduced = true
		end
		gfx.drawText("(b) to switch layer", 10, 70)
		
	end
end

--#endregion


--#region handling the state of the game

local gamestate <const> = {
	preview = 0, -- originally intended for coverimage, you could use it for an intro sequence with yalls logo or sth like that
	menu = 1,
	game_intro = 2,
	game_playing = 3,
	game_over = 4,
	postgame = 5,
	gallery_menu = 6,
	gallery_display = 7,
	options_menu = 8,
}

current_state = gamestate.preview

local menu_font = gfx.font.new("font/Asheville-Sans-14-Bold")
local change_state = {
	[gamestate.preview] = function ()
		gfx.setFont(menu_font)
		pd.display.setScale(1)
		current_state = gamestate.preview
	end,
	
	[gamestate.menu] = function ()
		gfx.setFont(menu_font)
		pd.display.setScale(1)
		current_state = gamestate.menu
	end,
	
	[gamestate.game_intro] = function ()
		gfx.setFont(menu_font)
		pd.display.setScale(2)
		current_state = gamestate.game_intro
	end,
	
	[gamestate.game_playing] = function ()
		pd.display.setScale(2)
		current_state = gamestate.game_playing
		begin_game()
	end,
	
	[gamestate.game_over] = function ()
		gfx.setFont(menu_font)
		pd.display.setScale(2)
		current_state = gamestate.game_over
	end,
	
	[gamestate.postgame] = function ()
		gfx.setFont(menu_font)
		pd.display.setScale(1)
		current_state = gamestate.postgame
	end,
	
	[gamestate.gallery_menu] = function ()
		gfx.setFont(menu_font)
		pd.display.setScale(1)
		
		pd.getCrankTicks(gallery_crank_ticks) -- this flushes any ticks that might ve accumulated since last time it was called
		
		load_gallery_saves()
		
		current_state = gamestate.gallery_menu
	end,
	
	[gamestate.gallery_display] = function ()
		gfx.setFont(menu_font)
		pd.display.setScale(1)

		current_state = gamestate.gallery_display
	end,
	
	
	[gamestate.options_menu] = function ()
		gfx.setFont(menu_font)
		pd.display.setScale(1)
		
		current_state = gamestate.options_menu
		pd.getCrankTicks(option_crank_ticks)
		load_preferences()
	end
}

pd.getSystemMenu():addMenuItem("preferences", function()
	change_state[gamestate.options_menu]()
	sfx_menu_next()
end)

local state_update = {
	[gamestate.preview] = function ()
		gfx.drawText("preview", 0,0)
--		-~</your ad here/>~-  -~ ~-
		change_state[gamestate.menu]()
	end,
	
	[gamestate.menu] = function ()
		gfx.drawText("menu\n(b) to play\n(a) to see gallery", 5,5)
		
		if pd.buttonJustPressed(pd.kButtonB) then
			-- feel free to make it not secret, but if it dont fit the chosen aesthetic pls dont remove, i like fucking around in it, also ppl like secrets :)
			secret_circuitboard_mode = pd.buttonIsPressed(pd.kButtonUp) and pd.buttonIsPressed(pd.kButtonRight) and secret_other_condition
			if onboarded() then
				change_state[gamestate.game_playing]()
				sfx_start_game()
			else
				change_state[gamestate.game_intro]()
				sfx_menu_next()
			end
		elseif  pd.buttonJustPressed(pd.kButtonA) then
			change_state[gamestate.gallery_menu]()
			sfx_menu_next()
		end
	end,
	
	[gamestate.game_intro] = function ()
		display_onboarding()
		if onboarded() then
			change_state[gamestate.game_playing]()
			sfx_start_game()
		end
	end,
	
	[gamestate.game_playing] = function ()
		move_player()
		
		-- sample("try collide			", function()
		collide_and_swap_layer()
		-- end)
		
		consider_collecting_a_portal()
		
		playing_state_inputs()
		
		consider_placing_a_portal()
		
		-- sample("past trail to texture", function()
		consider_placing_a_point()
		-- end)
		
		-- compose render image
		sample("compose image		", function()
			compose_image()
		end)
		
		-- sample("render in perspective", function()
		render_in_perspective()
		-- end)

		
		-- sample("display to scren	", function()
		display_render()
		-- end)
		
		-- sample("debug draws			", function()
			-- draw_debug_info()
		draw_score()
		-- end)
		
		animate_camera()
		
		if not player.alive then
			sfx_death()
			change_state[gamestate.game_over]()
		end
		
	end,
	
	[gamestate.game_over] = function ()
		
		-- if skipping this step is not an issue or there is a tiny delay to let it sink it
		-- using B could help the flow feel nicer, though i don't want people to accidentally skip through the next few stages
		
		animate_camera()
		
		-- compose render image
		-- sample("compose image		", function()
		compose_image()
		-- end)
		
		-- sample("render in perspective", function()
		render_in_perspective()
		-- end)
		
		-- sample("display to scren	", function()
		display_render()
		-- end)
		
		gfx.setColor(white)
		gfx.fillRect(0,0, 200, 50)
		gfx.drawText("u died and r dead\n(a) to proceed", 3,3)
		
		-- draw_score()
		-- draw_debug_info()
		-- draw_collision_debug()
	
		if pd.buttonJustPressed(pd.kButtonA) then
			secret_other_condition = pd.buttonIsPressed(pd.kButtonB)
			render_sexy_scrolling_image()
			
			change_state[gamestate.postgame]()
			sfx_menu_next()
		end
	end,
	
	[gamestate.postgame] = function ()
		
		gfx.clear(white)
		
		update_image_scroll_offset()
		draw_scrolling_image()
		
		gfx.drawText("your score is "..tostring(player.score).."\n(b) to play again\n(a) to save drawing", 5,5)
		
		pd.drawFPS(0, 0)
		
		if pd.buttonJustPressed(pd.kButtonB) then
			change_state[gamestate.menu]()
			sfx_menu_next()
		elseif pd.buttonJustPressed(pd.kButtonA) then
			
			save_scrolling_image_to_gallery() -- add extra info like score here 
			current_gallery_index = #gallery_saves_table
			change_state[gamestate.gallery_menu]()
			sfx_menu_next()
		end
	end,
	
	[gamestate.gallery_menu] = function ()
		gfx.setFont(menu_font)
		gfx.drawText("gallery menu\n(a) to view selected    (b) to go to menu\ncrank and dup ddown to choose image\ndleft to delete    dright to rename", 5,5)
		display_gallery()
		
		-- ik its cringe to put them here but lua reads code from top to down
		if (not renaming) and (not deleting) then
			if pd.buttonJustPressed(pd.kButtonA)  and #gallery_saves_table > 0 then
				load_scrolling_image_from_gallery_save(gallery_saves_table[current_gallery_index])
				
				change_state[gamestate.gallery_display]()
				sfx_menu_next()
			elseif pd.buttonJustPressed(pd.kButtonB) then
				change_state[gamestate.menu]()
				sfx_menu_back()
			end
		end	
		
		gallery_scrolling()
	end,
	
	[gamestate.gallery_display] = function ()
		gfx.clear(white)
		update_image_scroll_offset()
		draw_scrolling_image()
		
		gfx.setColor(white)
		gfx.fillRect(0,0, 400, 45)
		gfx.drawText("saved img view\n(a) or (b) to go back", 5,5)
		
		if pd.buttonJustPressed(pd.kButtonA) or pd.buttonJustPressed(pd.kButtonB) then
			change_state[gamestate.gallery_menu]()
			sfx_menu_back()
		end
	end,
	
	[gamestate.options_menu] = function ()
		-- print("currently in the options")
		pd.getCrankTicks(gallery_crank_ticks)
		
		options_inputs()
		options_display()
		
		if pd.buttonJustPressed(pd.kButtonB) then
			sfx_menu_back()
			-- save_preferences()
			change_state[gamestate.menu]()
		end
	end
}

--#endregion


function pd.update()
	gfx.clear(white)
	
	local update_function = state_update[current_state]
	if (update_function) then
		update_function()
	-- else
	-- 	print("i dont know what a "..tostring(current_state).." state index is supposed to mean")
	-- 	print("but i'm not gonna just chill here in the void either")
	-- 	print("off to the menu with you!")
	-- 	change_state[gamestate.menu]()
	end
	
	pd.drawFPS(0,0)

	pd.timer.updateTimers() -- manual said some built-in things need it to function
end
