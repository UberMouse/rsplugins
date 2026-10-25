-- Part of main.lua's environment probe: hands back this module's view of the globals, so
-- main.lua can check whether a required module shares its environment.
return { env = _ENV, event = Event }
