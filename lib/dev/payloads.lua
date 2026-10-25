-- The fields of each event's payload, from the <Name>EventPayload classes in
-- docs/api/generated/core/events.lua. The recorder reads these by name, because a payload's
-- fields can't be listed at runtime: the test harness's payloads can't be iterated, and whether
-- the client's can is undocumented. An event missing here is still recorded, as whatever its
-- payload serialises to. Events without a payload (ServerLogic, WorldUpdated, RegionUpdated)
-- need no entry.

-- stylua: ignore
return {
    Logic = { "logicTick" },
    Draw = { "timeDeltaSecs" },
    OptionalDependencyChanged = { "pluginIdentifier", "enabled" },
    OptionalPermissionChanged = { "permissionName", "enabled" },
    KeyUp = { "gameKey", "systemKey", "modifiers", "timestamp" },
    KeyDown = { "isRepeat", "gameKey", "systemKey", "modifiers", "timestamp" },
    KeyTyped = { "char", "modifiers", "timestamp" },
    VarTransmit = { "var", "oldValue", "newValue" },
    ChatMessage = {
        "chatMessage", "senderNameUnfiltered", "senderNameFiltered", "senderNameSimple",
        "chatType", "timestamp",
    },
    PlayerEntityAdded = { "playerEntity", "entityType" },
    PlayerEntityRemoved = { "playerEntity", "entityType" },
    NPCEntityAdded = { "npcEntity", "entityType" },
    NPCEntityRemoved = { "npcEntity", "entityType" },
    ObjStackEntityAdded = { "objStackEntity", "entityType", "objType", "count", "isOwner" },
    ObjStackEntityRemoved = { "objStackEntity", "entityType", "objType", "count", "isOwner" },
    ObjStackEntityChanged = {
        "objStackEntity", "entityType", "objType", "oldCount", "newCount", "isOwner",
    },
    WindowFocusChanged = { "hasFocus" },
    GameStateChanged = { "oldState", "newState" },
    EntityDraw = { "entityType", "npcEntity", "playerEntity", "objStackEntity" },
    WindowSizeChanged = { "oldWidth", "oldHeight", "newWidth", "newHeight" },
    SkillTransmit = { "skill", "oldXP", "newXP", "oldGameplayLevel", "newGameplayLevel" },
    RunEnergyTransmit = { "oldRunEnergy", "newRunEnergy" },
    RunWeightTransmit = { "oldRunWeight", "newRunWeight" },
    MiniMenuOpened = { "miniMenu" },
    MiniMenuClosed = { "miniMenu" },
    MiniMenuReady = { "miniMenu" },
    MiniMenuEntryAdded = { "entry" },
    MiniMenuEntrySelected = { "entry" },
    LocAdded = {
        "config", "shapeType", "rotationType", "coordGrid", "overrideTransform",
        "transformTranslate", "transformRotation", "transformScale",
    },
    LocRemoved = { "shapeType", "rotationType", "coordGrid" },
    LocCustomised = {
        "config", "shapeType", "rotationType", "coordGrid", "customModels", "customColours",
        "customMaterials",
    },
    LocAnimation = { "shapeType", "rotationType", "coordGrid", "animation", "animationDelay" },
    InventoryAdded = { "inv" },
    InventoryUpdated = { "inv", "slotsUpdated" },
    InventoryRemoved = { "inv" },
    GrandExchangeOfferUpdated = { "slot", "listing" },
    WorldCreated = { "mapSquareMinX", "mapSquareMinZ", "mapSquareMaxX", "mapSquareMaxZ" },
    RegionCreated = {
        "mapSquareMinX", "mapSquareMinZ", "mapSquareMaxX", "mapSquareMaxZ", "regionGridCorner",
        "regionGridWidth", "regionGridLength",
    },
    SettingsLayerReady = { "component" },
    ContentLayerReady = { "component" },
}
