--!strict

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Replication
local Replication = ReplicatedStorage:WaitForChild("Replication")
local CurrencyReplication = require(Replication:WaitForChild("CurrencyReplication"))

local PATH_WIDTH = 5

export type CrateConfig = {
	Kind: string?,
	Speed: number,
	Health: number,
	Damage: number?,
	CurrencyDrops: { CurrencyReplication.CurrencyDrop }?,
	LootCrate: string?,
	XPReward: number?,
}

type CrateProperties = {
	Id: number,
	PlotId: string,
	LaneId: string,
	CrateType: string,
	Waypoints: { Vector3 },
	_cumulative: { number },
	WaypointIndex: number,
	Position: Vector3,
	Speed: number,
	MaxHealth: number,
	Health: number,
	-- Dealt to the plot's base if this crate survives to the end of its lane. Zero for
	-- every kind but "Damage", which is what makes a leaked reward crate harmless.
	Damage: number,
	Alive: boolean,
	ReachedEnd: boolean,
	CurrencyDrops: { CurrencyReplication.CurrencyDrop }?,
	-- Key into Indexes/LootCrates, granted whole on a player kill (Kind "Loot").
	LootCrate: string?,
	XPReward: number?,
	_spawnOffset: Vector3,
}

local ServerCrate = {}
ServerCrate.__index = ServerCrate

export type ServerCrate = typeof(setmetatable({} :: CrateProperties, ServerCrate))

--[=[
	Picks a random horizontal offset inside the PATH_WIDTH square (Y stays 0).
	@return Vector3 -- The spawn offset.
]=]
local function randomSpawnOffset(): Vector3
	local half = PATH_WIDTH / 2
	return Vector3.new((math.random() * 2 - 1) * half, 0, (math.random() * 2 - 1) * half)
end

--[=[
	Creates a server crate positioned at the first waypoint of its lane, shifted by
	a random spawn offset it keeps for its whole path.
	@param id number -- Network id assigned by CrateService.
	@param plotId string -- Plot the crate belongs to.
	@param laneId string -- Lane whose waypoints the crate follows.
	@param crateType string -- Crate type key (matches the crate index).
	@param waypoints { Vector3 } -- Ordered path the crate walks.
	@param cumulative { number } -- Per-waypoint path length to the end (from PathService).
	@param config CrateConfig -- Speed/health/reward configuration for this type.
	@return ServerCrate -- The constructed crate.
]=]
function ServerCrate.new(
	id: number,
	plotId: string,
	laneId: string,
	crateType: string,
	waypoints: { Vector3 },
	cumulative: { number },
	config: CrateConfig
): ServerCrate

	local self = setmetatable({}, ServerCrate) :: ServerCrate
	self.Id = id
	self.PlotId = plotId
	self.LaneId = laneId
	self.CrateType = crateType
	self.Waypoints = waypoints
	self._cumulative = cumulative
	self.WaypointIndex = 1
	self._spawnOffset = randomSpawnOffset()
	self.Position = waypoints[1] + self._spawnOffset
	self.Speed = config.Speed
	self.MaxHealth = config.Health
	self.Health = config.Health
	self.Damage = config.Damage or 0
	self.LootCrate = config.LootCrate
	self.Alive = true
	self.ReachedEnd = false
	self.CurrencyDrops = config.CurrencyDrops
	self.XPReward = config.XPReward
	return self
end

--[=[
	Advances the crate along its lane by one simulation step. Sets ReachedEnd once
	the final waypoint is passed. Dead or finished crates are skipped.
	@param deltaTime number -- Seconds elapsed since the previous step.
	@param speedMultiplier number -- Plot-wide speed multiplier (1 = normal; potions change it).
	@return () -- No return value.
]=]
function ServerCrate:StepMovement(deltaTime: number, speedMultiplier: number)
	local self = self :: ServerCrate
	if not self.Alive or self.ReachedEnd then
		return
	end

	local nextWaypoint = self.Waypoints[self.WaypointIndex + 1]
	if not nextWaypoint then
		self.ReachedEnd = true
		return
	end

	local target = nextWaypoint + self._spawnOffset
	local toTarget = target - self.Position
	local distance = toTarget.Magnitude
	local step = self.Speed * speedMultiplier * deltaTime

	if step >= distance then
		self.Position = target
		self.WaypointIndex += 1
	else
		self.Position += toTarget.Unit * step
	end
end

--[=[
	Applies damage and flags the crate dead when its health is depleted.
	@param amount number -- Damage to subtract from current health.
	@return number -- Remaining health after the damage is applied.
]=]
function ServerCrate:TakeDamage(amount: number): number
	local self = self :: ServerCrate
	self.Health -= amount
	if self.Health <= 0 then
		self.Alive = false
	end
	return self.Health
end

--[=[
	Returns the remaining distance along the path from this crate to the final
	waypoint: the cached path length from the next waypoint to the end, plus the
	straight distance from the crate's on-path position to that next waypoint. Runs
	on the raw centre line (the spawn offset is removed), so it is correct through
	corners and independent of the offset. Smaller = closer to the end.
	@return number -- Remaining path distance to the end.
]=]
function ServerCrate:GetDistanceToEnd(): number
	local self = self :: ServerCrate
	local nextIndex = self.WaypointIndex + 1
	local nextWaypoint = self.Waypoints[nextIndex]
	if not nextWaypoint then
		return 0
	end
	local onPathPosition = self.Position - self._spawnOffset
	return self._cumulative[nextIndex] + (nextWaypoint - onPathPosition).Magnitude
end

return ServerCrate
