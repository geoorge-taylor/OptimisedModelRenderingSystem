--!strict

-- Services
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

-- Framework
local Framework = ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Framework")
local Socket = require(Framework:WaitForChild("ClientSocket"))

-- Classes
local Classes = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Classes")
local ClientCrate = require(Classes:WaitForChild("ClientCrate"))
local TemplatePool = require(Classes:WaitForChild("TemplatePool"))

-- Other controllers
local Controllers = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Controllers")
local CrateEffectsController = require(Controllers:WaitForChild("CrateEffectsController"))

-- Replication
local Replication = ReplicatedStorage:WaitForChild("Replication")
local CrateReplication = require(Replication:WaitForChild("CrateReplication"))

-- Assets
local CrateModels = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Crates")

-- Workspace
local CratesFolder = Workspace:WaitForChild("Crates")

local PREWARM_PER_TYPE = 15

type CrateRenderControllerProperties = {
	Socket: Socket.ClientSocket,
	ActiveCrates: { [number]: ClientCrate.ClientCrate },
	ModelPool: TemplatePool.TemplatePool,
	_moveParts: { BasePart },
	_moveCFrames: { CFrame },
	_activeAuras: { [string]: true },
}

local CrateRenderController = {}
CrateRenderController.__index = CrateRenderController

export type CrateRenderController = typeof(setmetatable({} :: CrateRenderControllerProperties, CrateRenderController))

--[=[
	Builds a full world position from planar (X, Z) coordinates at the shared crate
	ground height.
	@param x number -- World X.
	@param z number -- World Z.
	@return Vector3 -- Full world position at the shared ground height.
]=]
local function worldPosition(x: number, z: number): Vector3
	return Vector3.new(x, CrateReplication.GroundHeight, z)
end

--[=[
	Opens the socket, initialises the active-crate table, builds the model pool, and
	allocates the reusable BulkMoveTo buffers.
	@return () -- No return value.
]=]
function CrateRenderController:Init()
	local self = self :: CrateRenderController
	self.Socket = Socket.new("CrateService")
	self.ActiveCrates = {}
	self.ModelPool = TemplatePool.new(CrateModels, CratesFolder)
	self.ModelPool:PrewarmAll(PREWARM_PER_TYPE)
	self._moveParts = {}
	self._moveCFrames = {}
	self._activeAuras = {}
end

--[=[
	Subscribes to the crate replication events and starts the render loop.
	@return () -- No return value.
]=]
function CrateRenderController:Start()
	local self = self :: CrateRenderController
	self.Socket:Connect(CrateReplication.CRATE_SPAWNED, function(payload: CrateReplication.CrateSpawnedPayload)
		self:_onCrateSpawned(payload)
	end)

	self.Socket:Connect(CrateReplication.CRATE_DESPAWNED, function(id: number, reason: CrateReplication.DespawnReason)
		self:_onCrateDespawned(id, reason)
	end)

	self.Socket:Connect(CrateReplication.CRATE_DAMAGED, function(id: number, damage: number, healthFraction: number, crit: boolean?, fromWeapon: boolean?)
		self:_onCrateDamaged(id, damage, healthFraction, fromWeapon, crit)
	end)

	self.Socket:Connect(CrateReplication.BATCHED_CRATE_POSITIONS, function(positions: buffer)
		self:_onPositionsUpdated(positions)
	end)

	RunService.Heartbeat:Connect(function(deltaTime: number)
		self:_renderStep(deltaTime)
	end)
end

--[=[
	Returns the ClientCrate for a network id, or nil if it isn't tracked.
	@param id number -- Crate network id.
	@return ClientCrate.ClientCrate? -- The tracked crate, or nil.
]=]
function CrateRenderController:GetCrate(id: number): ClientCrate.ClientCrate?
	local self = self :: CrateRenderController
	return self.ActiveCrates[id]
end

--[=[
	Applies the "was hit" feedback to a set of crates and plays one hit sound.
	@param crateIds { number } -- Network ids of the crates that were hit.
	@return () -- No return value.
]=]
function CrateRenderController:ApplyHits(crateIds: { number })
	local self = self :: CrateRenderController
	local soundCFrame: CFrame? = nil
	for _, id in ipairs(crateIds) do
		local crate = self.ActiveCrates[id]
		if crate then
			CrateEffectsController:PlayHighlight(crate.Model)
			if not soundCFrame then
				soundCFrame = crate.Part.CFrame
			end
		end
	end

	if soundCFrame then
		CrateEffectsController:PlayHitSound(soundCFrame)
	end
end

--[=[
	Turns a potion aura on/off for the whole plot: applies/removes it on every current
	crate and remembers it so future spawns get it too. Called by PotionController.
	@param potionType string -- The potion type whose aura to toggle.
	@param active boolean -- Whether the aura is on.
	@return () -- No return value.
]=]
function CrateRenderController:SetPotionAura(potionType: string, active: boolean)
	local self = self :: CrateRenderController
	if active then
		self._activeAuras[potionType] = true
		for _, crate in pairs(self.ActiveCrates) do
			CrateEffectsController:ApplyPotionAura(crate.Model, potionType)
		end
	else
		self._activeAuras[potionType] = nil
		for _, crate in pairs(self.ActiveCrates) do
			CrateEffectsController:ClearPotionAura(crate.Model, potionType)
		end
	end
end

--[=[
	Updates a crate's health bar and spawns a floating damage number.
	@param id number -- Network id of the damaged crate.
	@param damage number -- Damage dealt.
	@param healthFraction number -- Remaining health as a 0..1 fraction.
	@param crit boolean? -- Whether this hit critically struck.
	@return () -- No return value.
]=]
function CrateRenderController:_onCrateDamaged(id: number, damage: number, healthFraction: number, fromWeapon: boolean?, crit: boolean?)
	local self = self :: CrateRenderController
	local crate = self.ActiveCrates[id]
	if crate then
		crate:UpdateHealth(healthFraction)
		CrateEffectsController:PlayDamageNumber(crate.Part.CFrame, damage, crit)
		if healthFraction > 0 and fromWeapon then
			crate:Shake()
		end
	end
end

--[=[
	Acquires a pooled model for a newly spawned crate and starts tracking it.
	@param payload CrateReplication.CrateSpawnedPayload -- Spawn data from the server.
	@return () -- No return value.
]=]
function CrateRenderController:_onCrateSpawned(payload: CrateReplication.CrateSpawnedPayload)
	local self = self :: CrateRenderController
	local model = self.ModelPool:Acquire(payload.CrateType)
	if not model then
		return
	end

	local crate = ClientCrate.new(
		payload.Id,
		payload.PlotId,
		payload.CrateType,
		worldPosition(payload.Position.X, payload.Position.Y),
		model
	)
	self.ActiveCrates[payload.Id] = crate
	for potionType in pairs(self._activeAuras) do
		CrateEffectsController:ApplyPotionAura(crate.Model, potionType)
	end
end

--[=[
	Unpacks a position buffer and points each tracked crate at its new target.
	@param positions buffer -- Packed positions (see CrateReplication for layout).
	@return () -- No return value.
]=]
function CrateRenderController:_onPositionsUpdated(positions: buffer)
	local self = self :: CrateRenderController
	local layout = CrateReplication.PositionBuffer
	for offset = 0, buffer.len(positions) - 1, layout.RecordSize do
		local id = buffer.readu16(positions, offset + layout.IdOffset)
		local crate = self.ActiveCrates[id]
		if crate then
			local x = buffer.readf32(positions, offset + layout.XOffset)
			local z = buffer.readf32(positions, offset + layout.ZOffset)
			crate:UpdateTarget(worldPosition(x, z))
		end
	end
end

--[=[
	Plays the destroy effect (only for a killed crate), returns the model to the
	pool and stops tracking the crate.
	@param id number -- Network id of the crate to remove.
	@param reason CrateReplication.DespawnReason -- Why it despawned.
	@return () -- No return value.
]=]
function CrateRenderController:_onCrateDespawned(id: number, reason: CrateReplication.DespawnReason)
	local self = self :: CrateRenderController
	local crate = self.ActiveCrates[id]
	if crate then
		CrateEffectsController:ClearHighlight(crate.Model)
		CrateEffectsController:ClearAllAuras(crate.Model)
		if reason == "Killed" then
			CrateEffectsController:PlayDestroyed(crate.Part.CFrame)
		end
		local model = crate:PrepareForPool()
		self.ModelPool:Release(crate.CrateType, model)
		self.ActiveCrates[id] = nil
	end
end

--[=[
	Advances every tracked crate's interpolation and applies all moves in one
	batched Workspace:BulkMoveTo.
	@param deltaTime number -- Seconds since the previous frame.
	@return () -- No return value.
]=]
function CrateRenderController:_renderStep(deltaTime: number)
	local self = self :: CrateRenderController
	local parts = self._moveParts
	local cframes = self._moveCFrames
	table.clear(parts)
	table.clear(cframes)

	for _, crate in pairs(self.ActiveCrates) do
		local cframe = crate:StepInterpolation(CrateReplication.TickRate, deltaTime)
		table.insert(parts, crate.Part)
		table.insert(cframes, cframe)
	end

	if #parts > 0 then
		Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

return (CrateRenderController :: any) :: CrateRenderController
