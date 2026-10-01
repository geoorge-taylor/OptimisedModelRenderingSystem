--!strict

-- Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Framework
local Framework = ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Framework")
local Socket = require(Framework:WaitForChild("ServerSocket"))

-- Classes
local Classes = ServerScriptService:WaitForChild("Classes")
local ServerCrate = require(Classes:WaitForChild("ServerCrate"))

-- Other services
local Services = ServerScriptService:WaitForChild("Services")
local PathService = require(Services:WaitForChild("PathService"))
local PlotService = require(Services:WaitForChild("PlotService"))
local RewardService = require(Services:WaitForChild("RewardService"))
local PotionService = require(Services:WaitForChild("PotionService"))
local EndpointService = require(Services:WaitForChild("EndpointService"))

-- Replication / Data
local Replication = ReplicatedStorage:WaitForChild("Replication")
local CrateReplication = require(Replication:WaitForChild("CrateReplication"))
local CrateIndex = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Data"):WaitForChild("Indexes"):WaitForChild("Crates"))

local PositionBuffer = CrateReplication.PositionBuffer

type CrateServiceProperties = {
	Crates: { [number]: ServerCrate.ServerCrate },
	Socket: Socket.ServerSocket,
	_sinceLastNetworkTick: number,
	_nextNetworkId: number,
	_freeNetworkIds: { number },
	_onCrateRemoved: { (crate: ServerCrate.ServerCrate, reason: CrateReplication.DespawnReason) -> () },
}

local CrateService = {}
CrateService.__index = CrateService

export type CrateService = typeof(setmetatable({} :: CrateServiceProperties, CrateService))

--[=[
	Writes one crate's position record into a buffer at the given offset.
	@param packed buffer -- Destination buffer.
	@param offset number -- Byte offset of this record's start.
	@param crate ServerCrate.ServerCrate -- The crate whose id/position to write.
	@return () -- No return value.
]=]
local function writeCrateRecord(packed: buffer, offset: number, crate: ServerCrate.ServerCrate)
	buffer.writeu16(packed, offset + PositionBuffer.IdOffset, crate.Id)
	buffer.writef32(packed, offset + PositionBuffer.XOffset, crate.Position.X)
	buffer.writef32(packed, offset + PositionBuffer.ZOffset, crate.Position.Z)
end

--[=[
	Packs the crates on a player's visible plots into a single position buffer.
	@param visiblePlotIds { string } -- Plots the player currently views.
	@param cratesByPlot { [string]: { ServerCrate.ServerCrate } } -- Live crates grouped by plot.
	@return buffer? -- The packed buffer, or nil if the player has no crates to send.
]=]
local function buildPositionBuffer(
	visiblePlotIds: { string },
	cratesByPlot: { [string]: { ServerCrate.ServerCrate } }
): buffer?

	local count = 0
	for _, plotId in ipairs(visiblePlotIds) do
		local list = cratesByPlot[plotId]
		if list then
			count += #list
		end
	end

	if count == 0 then
		return nil
	end

	local packed = buffer.create(count * PositionBuffer.RecordSize)
	local offset = 0
	for _, plotId in ipairs(visiblePlotIds) do
		local list = cratesByPlot[plotId]
		if list then
			for _, crate in ipairs(list) do
				writeCrateRecord(packed, offset, crate)
				offset += PositionBuffer.RecordSize
			end
		end
	end
	return packed
end

--[=[
	Initialises crate storage, the network tick accumulator, the id allocator and
	the socket.
	@return () -- No return value.
]=]
function CrateService:Init()
	local self = self :: CrateService
	self.Crates = {}
	self.Socket = Socket.new(script.Name)
	self._sinceLastNetworkTick = 0
	self._nextNetworkId = 0
	self._freeNetworkIds = {}
	self._onCrateRemoved = {}
end

--[=[
	Starts the per-frame simulation loop.
	@return () -- No return value.
]=]
function CrateService:Start()
	local self = self :: CrateService
	RunService.Heartbeat:Connect(function(deltaTime: number)
		self:_simulate(deltaTime)
	end)
end

--[=[
	Spawns a crate on the given lane and replicates the spawn to the players who
	view its plot. Dropped entirely if no ready player has claimed the plot.
	@param plotId string -- Plot the crate belongs to.
	@param crateType string -- Crate type key (matches the crate index).
	@param laneId string -- Lane whose waypoints the crate follows.
	@return ServerCrate.ServerCrate? -- The spawned crate, or nil if dropped/invalid.
]=]
function CrateService:SpawnCrate(
	plotId: string,
	crateType: string,
	laneId: string
): ServerCrate.ServerCrate?

	local self = self :: CrateService
	if not PlotService:IsClaimed(plotId) then
		return nil
	end

	local waypoints = PathService:GetLane(plotId, laneId)
	local cumulative = PathService:GetLaneCumulative(plotId, laneId)
	if not waypoints or not cumulative then
		return nil
	end

	local config = CrateIndex[crateType] :: ServerCrate.CrateConfig?
	if not config then
		print('no crate config for '..crateType)
		return nil
	end
	
	print('creaing a crate for '..crateType)
	local crate = ServerCrate.new(self:_allocateNetworkId(), plotId, laneId, crateType, waypoints, cumulative, config)
	self.Crates[crate.Id] = crate

	local spawnPayload: CrateReplication.CrateSpawnedPayload = {
		Id = crate.Id,
		PlotId = crate.PlotId,
		CrateType = crateType,
		Position = Vector2.new(crate.Position.X, crate.Position.Z),
	}
	for _, player in ipairs(PlotService:GetViewers(crate.PlotId)) do
		self.Socket:Fire(player, CrateReplication.CRATE_SPAWNED, spawnPayload)
	end

	return crate
end

--[=[
	Registers a callback run whenever a crate leaves play, with the reason it left.
	@param callback (crate: ServerCrate.ServerCrate, reason: CrateReplication.DespawnReason) -> () -- Run per removal.
	@return () -- No return value.
]=]
function CrateService:OnCrateRemoved(
	callback: (crate: ServerCrate.ServerCrate, reason: CrateReplication.DespawnReason) -> ()
)

	local self = self :: CrateService
	table.insert(self._onCrateRemoved, callback)
end

--[=[
	Removes every crate on a plot at once, without any of them counting as killed or
	leaked. Used to clear the field when a wave is cut short.
	@param plotId string -- Plot to clear.
	@return number -- How many crates were removed.
]=]
function CrateService:ClearPlotCrates(plotId: string): number
	local self = self :: CrateService

	-- Collected first: _removeCrate mutates the table being walked.
	local doomed = {}
	for _, crate in pairs(self.Crates) do
		if crate.PlotId == plotId then
			table.insert(doomed, crate)
		end
	end

	for _, crate in doomed do
		self:_removeCrate(crate, "Cleared")
	end
	return #doomed
end

--[=[
	Reads a crate by network id.
	@param crateId number -- Network id of the crate.
	@return ServerCrate.ServerCrate? -- The crate, or nil if it does not exist.
]=]
function CrateService:GetCrate(crateId: number): ServerCrate.ServerCrate?
	local self = self :: CrateService
	return self.Crates[crateId]
end

--[=[
	Returns every alive crate on a plot within a radius of a point.
	@param plotId string -- Plot to search.
	@param position Vector3 -- Centre of the search (the robot's position).
	@param range number -- Radius in studs.
	@return { ServerCrate.ServerCrate } -- Crates in range (may be empty).
]=]
function CrateService:GetCratesInRange(plotId: string, position: Vector3, range: number): { ServerCrate.ServerCrate }
	local self = self :: CrateService
	local rangeSquared = range * range
	local result = {}
	for _, crate in pairs(self.Crates) do
		if crate.Alive and crate.PlotId == plotId then
			local offset = crate.Position - position
			if offset:Dot(offset) <= rangeSquared then
				table.insert(result, crate)
			end
		end
	end
	return result
end

--[=[
	Applies damage to a crate and removes it if the damage was fatal. If the fatal
	blow came from a player, that player is granted the crate's reward.
	@param crateId number -- Network id of the crate to damage.
	@param amount number -- Damage to apply.
	@param source Player? -- The player who dealt the damage (nil for non-player damage).
	@param crit boolean? -- Whether this hit critically struck (drives the client visual).
	@return boolean -- True if the crate was destroyed by this damage.
]=]
function CrateService:DamageCrate(crateId: number, amount: number, source: Player?, crit: boolean?, fromWeapon: boolean?): boolean
	local self = self :: CrateService
	local crate = self.Crates[crateId]
	if not crate then
		return false
	end

	local health = crate:TakeDamage(amount)
	self:_broadcastDamage(crate, amount, math.max(health, 0) / crate.MaxHealth, crit == true, fromWeapon == true)

	if health <= 0 then
		if source then
			RewardService:GrantCrateReward(source, crate)
		end
		self:_removeCrate(crate, "Killed")
		return true
	end
	return false
end

--[=[
	Allocates a network id, reusing the OLDEST freed one (FIFO). Ids are replicated
	as a u16, so a fresh id may never exceed PositionBuffer.MaxId; because freed ids
	are recycled, hitting that ceiling means MaxId crates are alive at once, which is
	a runaway spawn rather than a long session.
	@return number -- A network id not currently in use by any live crate.
]=]
function CrateService:_allocateNetworkId(): number
	local self = self :: CrateService
	local reused = table.remove(self._freeNetworkIds, 1)
	if reused then
		return reused
	end

	self._nextNetworkId += 1
	assert(
		self._nextNetworkId <= PositionBuffer.MaxId,
		`[CrateService] Exhausted crate network ids ({PositionBuffer.MaxId} live crates); ids replicate as u16`
	)
	return self._nextNetworkId
end

--[=[
	Tells the players who view a crate's plot how much damage it just took and its
	resulting health fraction.
	@param crate ServerCrate.ServerCrate -- The damaged crate.
	@param amount number -- Damage applied.
	@param fraction number -- Remaining health as a 0..1 fraction.
	@return () -- No return value.
]=]
function CrateService:_broadcastDamage(
	crate: ServerCrate.ServerCrate, 
	amount: number, 
	fraction: number, 
	crit: boolean, 
	fromWeapon: boolean
)
	
	local self = self :: CrateService
	for _, player in ipairs(PlotService:GetViewers(crate.PlotId)) do
		self.Socket:Fire(player, CrateReplication.CRATE_DAMAGED, crate.Id, amount, fraction, crit, fromWeapon)
	end
end

--[=[
	Steps every crate's movement, removes any that reached the end, and fires a
	batched position broadcast once per network tick.
	@param deltaTime number -- Seconds elapsed since the previous frame.
	@return () -- No return value.
]=]
function CrateService:_simulate(deltaTime: number)
	local self = self :: CrateService
	if not next(self.Crates) then
		return
	end

	local speedByPlot: { [string]: number } = {}
	for _, crate in pairs(self.Crates) do
		local multiplier = speedByPlot[crate.PlotId]
		if multiplier == nil then
			multiplier = PotionService:GetSpeedMultiplier(crate.PlotId)
			speedByPlot[crate.PlotId] = multiplier
		end
		crate:StepMovement(deltaTime, multiplier)
		if crate.ReachedEnd then
			-- Damage lands before removal, so the base is still hit even though the crate
			-- is about to stop existing.
			EndpointService:ApplyDamage(crate.PlotId, crate.Damage)
			self:_removeCrate(crate, "ReachedEnd")
		end
	end

	self._sinceLastNetworkTick += deltaTime
	if self._sinceLastNetworkTick >= CrateReplication.TickRate then
		self._sinceLastNetworkTick = 0
		self:_broadcastPositions()
	end
end

--[=[
	Gathers every live crate into per-plot lists, skipping dead/finished ones.
	@return { [string]: { ServerCrate.ServerCrate } } -- Live crates grouped by plot.
]=]
function CrateService:_collectLiveCratesByPlot(): { [string]: { ServerCrate.ServerCrate } }
	local self = self :: CrateService
	local cratesByPlot: { [string]: { ServerCrate.ServerCrate } } = {}
	for _, crate in pairs(self.Crates) do
		if crate.Alive and not crate.ReachedEnd then
			local list = cratesByPlot[crate.PlotId]
			if not list then
				list = {}
				cratesByPlot[crate.PlotId] = list
			end
			table.insert(list, crate)
		end
	end
	return cratesByPlot
end

--[=[
	Sends each player a position buffer for the crates on the plots they view.
	@return () -- No return value.
]=]
function CrateService:_broadcastPositions()
	local self = self :: CrateService
	local cratesByPlot = self:_collectLiveCratesByPlot()
	if not next(cratesByPlot) then
		return
	end

	for _, player in ipairs(Players:GetPlayers()) do
		local packed = buildPositionBuffer(PlotService:GetVisiblePlotIds(player), cratesByPlot)
		if packed then
			self.Socket:Fire(player, CrateReplication.BATCHED_CRATE_POSITIONS, packed)
		end
	end
end

--[=[
	Removes a crate from the simulation, tells the players who view its plot to
	despawn it, and returns its network id to the free-list for reuse.
	@param crate ServerCrate.ServerCrate -- The crate to remove.
	@param reason CrateReplication.DespawnReason -- Why it was removed.
	@return () -- No return value.
]=]
function CrateService:_removeCrate(crate: ServerCrate.ServerCrate, reason: CrateReplication.DespawnReason)
	local self = self :: CrateService
	self.Crates[crate.Id] = nil

	for _, player in ipairs(PlotService:GetViewers(crate.PlotId)) do
		self.Socket:Fire(player, CrateReplication.CRATE_DESPAWNED, crate.Id, reason)
	end

	table.insert(self._freeNetworkIds, crate.Id)

	for _, callback in self._onCrateRemoved do
		callback(crate, reason)
	end
end

return (CrateService :: any) :: CrateService
