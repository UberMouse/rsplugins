-- Hello World: smoke test that the dev_plugins setup works.
-- Enable with `pon hello-world` in the client console (Alt+`).

-- Runs once when the plugin is enabled or reloaded.
print("Hello world!")

-- log() is like print() but also reports where in the script it was called from.
log("hello-world loaded, Lua version:", _VERSION)

-- Called automatically when the plugin is disabled, reloaded, or the client closes.
-- Must be a global (not local) for the client to find it.
function PluginShutdown()
    print("Goodbye world!")
end
