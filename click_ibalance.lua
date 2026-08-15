local app = hs.application.find("iBalance")
if not app then
  print("App not found")
  return
end
print("Found app: " .. app:name() .. " PID: " .. app:pid())

local mainScreen = hs.screen.mainScreen()
local frame = mainScreen:frame()
print("Main screen frame: x="..frame.x.." y="..frame.y.." w="..frame.w.." h="..frame.h)

local originalPos = hs.mouse.absolutePosition()
print("Original mouse pos: " .. originalPos.x .. ", " .. originalPos.y)

positions = {
  {x = frame.w - 110, y = 12},
  {x = frame.w - 140, y = 12},
  {x = frame.w - 170, y = 12},
  {x = frame.w - 200, y = 12},
  {x = frame.w - 230, y = 12},
  {x = frame.w - 260, y = 12},
  {x = frame.w - 290, y = 12},
  {x = frame.w - 320, y = 12},
  {x = frame.w - 350, y = 12},
  {x = frame.w - 380, y = 12},
  {x = frame.w - 410, y = 12},
  {x = frame.w - 440, y = 12},
  {x = frame.w - 470, y = 12},
}

for i, pos in ipairs(positions) do
  print("Click attempt " .. i .. " at (" .. pos.x .. ", " .. pos.y .. ")")
  hs.mouse.absolutePosition(pos)
  hs.timer.usleep(100000)
  hs.eventtap.leftClick(pos)
  hs.timer.usleep(400000)
  local wins = app:allWindows()
  if #wins > 0 then
    print("Window appeared after click " .. i .. "! Count: " .. #wins)
    for j, w in ipairs(wins) do
      local f = w:frame()
      print("  Win " .. j .. ": " .. (w:title() or "no title") .. " ["..f.x..","..f.y.." "..f.w.."x"..f.h.."]")
    end
    hs.mouse.absolutePosition(originalPos)
    break
  end
end

hs.mouse.absolutePosition(originalPos)
print("Done")
