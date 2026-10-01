--!strict

export type PlotId = string

export type CrateSpawnedPayload = {
	Id: number,
	PlotId: PlotId,
	CrateType: string,
	Position: Vector2,
}

--[=[
	Why a crate stopped existing. "Cleared" is a bulk wipe with no gameplay meaning (the
	wave was cut short), so the client removes those crates without playing a kill or
	leak reaction for each one.
]=]
export type DespawnReason = "Killed" | "ReachedEnd" | "Cleared"

local CrateReplication = {
	CRATE_SPAWNED = "CRATE_SPAWNED",
	CRATE_DESPAWNED = "CRATE_DESPAWNED",
	CRATE_DAMAGED = "CRATE_DAMAGED",
	BATCHED_CRATE_POSITIONS = "BATCHED_CRATE_POSITIONS",

	TickRate = 1 / 20,
	GroundHeight = 1,

	PositionBuffer = {
		RecordSize = 10,
		IdOffset = 0,
		XOffset = 2,
		ZOffset = 6,
		-- Crate ids are written with buffer.writeu16, so no live crate may exceed this.
		-- CrateService recycles freed ids, so the ceiling is concurrent crates, not
		-- total crates spawned over the session.
		MaxId = 65535,
	},
}

return CrateReplication
