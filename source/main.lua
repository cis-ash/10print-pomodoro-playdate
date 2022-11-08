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

local pop = snd.sampleplayer.new("sounds/pop.wav")
local alarm = snd.sampleplayer.new("sounds/alarm.wav")
local pause = snd.sampleplayer.new("sounds/pause.wav")
local work = snd.sampleplayer.new("sounds/work.wav")
local rest = snd.sampleplayer.new("sounds/longbreak.wav")

function sfx_pop()
	pop:play(1)
end

function sfx_pauseresume()
	pause:play(1)
end

function sfx_alarm()
	alarm:play(0)
end
function stop_alarm()
	alarm:stop()
end

function sfx_towork()
	work:play(1)
end

function sfx_gorest()
	rest:play(1)
end


local chosen_id = 1
local timers = {work = 1, break_short = 2, break_long = 3}

local tstate = {ready = 0, running = 1, paused = 2, complete = 3}
local tstatus = tstate.ready



local current_timer = pd.timer.new(10.0, function ()
	-- timer ended
	tstatus = tstate.complete
	sfx_alarm()
end)
current_timer:pause()
current_timer.discardOnCompletion = false

local update_screen_timer = pd.timer.new(1.0, function ()
	-- update screen
end)
update_screen_timer:pause()
update_screen_timer.discardOnCompletion = false
update_screen_timer.repeats = true



local durations = {
	[timers.work] = 25.0,
	[timers.break_short] = 5.0,
	[timers.break_long] = 20.0,
}

-- pd.datastore.delete("preferences")
function load_prefs()
	local _read = pd.datastore.read("preferences")
	if _read == nil then
		save_prefs()
	else
		durations = _read
	end
	-- printTable(durations)
end

function save_prefs()
	printTable(durations)
	pd.datastore.write(durations, "preferences")
	load_prefs()
end


load_prefs()

local optionsmenu = pd.getSystemMenu()
optionsmenu:addOptionsMenuItem("work", {"10.0", "15.0", "20.0", "25.0", "30.0", "35.0", "40.0", "45.0"}, string.format("%.1f", durations[timers.work]), function (_value)
	-- print(durations[timers.work])
	durations[timers.work] = tonumber(_value)
	-- print("work upd")
	-- printTable(durations)
	save_prefs()
	-- print(tostring(tonumber(_value)))
end)

optionsmenu:addOptionsMenuItem("short", {"3.0", "4.0", "5.0", "6.0", "7.0", "8.0", "9.0", "10.0"}, string.format("%.1f", durations[timers.break_short]), function (_value)
	durations[timers.break_short] = tonumber(_value)
	-- print("break upd")
	-- printTable(durations)
	save_prefs()

end)

optionsmenu:addOptionsMenuItem("long", {"15.0", "20.0", "25.0", "30.0", "35.0", "40.0"}, string.format("%.1f", durations[timers.break_long]), function (_value)
	durations[timers.break_long] = tonumber(_value)
	-- print("long upd")
	-- printTable(durations)
	save_prefs()
end)



function setup()
	
end

function setup_timer(_id)
	current_timer:reset()
	current_timer.duration = durations[_id] * 1000 * 60
	current_timer:pause()
	-- print("current timer duration "..tostring(current_timer.duration).." paused "..tostring(current_timer.paused))
end

local work_without_longrest = 0
local font = gfx.font.new("font/Roobert-20-Medium")


local font10print = gfx.font.new("font/10print")
setup_timer(chosen_id)


local function update_text()
	gfx.setFont(font)
	gfx.setColor(white)
	gfx.fillRect(0,0, 400, 65)
		
	local id_name = ""
	if chosen_id == timers.work then id_name = "work timer" end
	if chosen_id == timers.break_short then id_name = "short break" end
	if chosen_id == timers.break_long then id_name = "long break" end

	local status_txt = ""
	if tstatus == tstate.ready then
		status_txt = "ready"
		gfx.drawTextAligned("change timer < >\nstart timer Ⓐ", 395,0, kTextAlignment.right)
	end
	-- if tstatus == tstate.running then status_txt = "running" end
	if tstatus == tstate.paused then
		status_txt = "paused"
		gfx.drawTextAligned("resume timer Ⓐ\nfinish timer Ⓑ", 395,0, kTextAlignment.right)
	end
	if tstatus == tstate.complete then
		status_txt = "completed"
		gfx.drawTextAligned("stop alarm Ⓐ", 395,0, kTextAlignment.right)
	end
	gfx.drawText(id_name.."\n"..status_txt, 5,0)
end


local printtexture = gfx.image.new(28, 20)


function draw_10print(_off_x, _off_y, _cellsize)
	gfx.setColor(white)
	gfx.fillRect(_off_x - _cellsize, _off_y - _cellsize, (printtexture.width + 2)*_cellsize, (printtexture.height + 2)*_cellsize)
	
	gfx.lockFocus(printtexture)
		gfx.clear(clear) -- make clear
		gfx.setFont(font10print)
		gfx.setColor(white)
		gfx.fillRect(0,5, 28, 9)
		local minutes = math.floor(current_timer.timeLeft/ 60000)
		local seconds = (current_timer.timeLeft / 1000) - minutes * 60
		local time_string = string.format("%02.0f:%02.0f", minutes, seconds)
		gfx.drawText(time_string,1,6)
	gfx.unlockFocus()
	
	gfx.setLineCapStyle(gfx.kLineCapStyleSquare)
	gfx.setLineWidth(7)
	gfx.setColor(black)
	
	for x=0, printtexture.width do
		for y=0, printtexture.height do
			local diagonal = printtexture:sample(x,y)
			
			local corner = geo.point.new(_off_x + x * _cellsize, _off_y + y * _cellsize)
			local flipped = nil
			
			if diagonal == black then
				flipped = true
			elseif diagonal == white then
				flipped = false
			else
				if tstatus == tstate.running then
					flipped = math.random() > 0.75
				else
					flipped = false
				end
			end
			
			if flipped then
				gfx.drawLine(corner.x, corner.y, corner.x + _cellsize, corner.y + _cellsize)
			else
				gfx.drawLine(corner.x, corner.y + _cellsize, corner.x + _cellsize, corner.y)
			end
		end
	end
end


function pd.update()

	
	if tstatus == tstate.complete then
		if pd.buttonJustPressed(pd.kButtonA) then
			stop_alarm()
			-- print("completed")
			print(chosen_id)
			if chosen_id == timers.work then
				-- print("was working")
				work_without_longrest += 1
				-- print("without rest for "..tostring(work_without_longrest))
				
				if work_without_longrest < 4 then
					chosen_id = timers.break_short
					-- print("shortbreak time")
				else
					chosen_id = timers.break_long
					-- print("longbreaktime")
				end
				
				setup_timer(chosen_id)
			elseif chosen_id == timers.break_short then
				-- print("rested, time for work")
				chosen_id = timers.work
			elseif chosen_id == timers.break_long then
				-- print("longrested, time for work")
				work_without_longrest = 0
				chosen_id = timers.work
			end
			setup_timer(chosen_id)
			tstatus = tstate.ready
			print("complete->ready")
			pd.setAutoLockDisabled(false)
			pd.display.setRefreshRate(10)
		end
	elseif tstatus == tstate.running then
		if pd.buttonJustPressed(pd.kButtonA) then
			print("running->paused")
			tstatus = tstate.paused
			current_timer:pause()
			sfx_pauseresume()
			pd.display.setRefreshRate(10)
		end
		-- if timer runs out - go to complete state
	elseif tstatus == tstate.ready then
		if pd.buttonJustPressed(pd.kButtonLeft) then 
			-- print("choose next, id "..tostring(chosen_id))
			chosen_id -= 1
			chosen_id = 1+ (chosen_id - 1) % 3
			setup_timer(chosen_id)
			sfx_pop()
		end
		if pd.buttonJustPressed(pd.kButtonRight) then 
			-- print("choose next, id "..tostring(chosen_id))
			chosen_id += 1
			chosen_id = 1+ (chosen_id - 1) % 3
			setup_timer(chosen_id)
			sfx_pop()
		end
		
		
		if pd.buttonJustPressed(pd.kButtonA) then
			tstatus = tstate.running
			current_timer:start()
			if chosen_id == timers.work then
				sfx_towork()
			else
				sfx_gorest()
			end
			-- print("starting timer")
			print("ready->running")
			pd.setAutoLockDisabled(true)
			pd.display.setRefreshRate(1)
		end
	elseif tstatus == tstate.paused then 
		if pd.buttonJustPressed(pd.kButtonA) then
			print("paused->running")
			tstatus = tstate.running
			current_timer:start()
			sfx_pauseresume()
			pd.display.setRefreshRate(1)
		end
		if pd.buttonJustPressed(pd.kButtonB) then
			-- print("paused->reset")
			-- tstatus = tstate.ready
			print("paused->complete")
			sfx_alarm()
			tstatus = tstate.complete -- for debug
			current_timer:reset()
			current_timer:pause()
			pd.display.setRefreshRate(10)
		end
	end
	
	if tstatus == tstate.complete or tstatus == tstate.ready or tstatus == tstate.paused then
		draw_10print(-4, 0, 15)
		update_text()
	else
		draw_10print(-4, -30, 15)
	end
	-- pd.drawFPS(385,225)
	
	pd.timer.updateTimers() -- manual said some built-in things need it to function
end
