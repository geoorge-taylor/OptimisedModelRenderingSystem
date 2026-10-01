-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Replication
local CurrencyReplication = require(ReplicatedStorage:WaitForChild("Replication"):WaitForChild("CurrencyReplication"))

export type CrateKind = "Damage" | "Loot" | "Currency"

--[=[
	The fields every crate has, whatever its kind. Kept separate so each variant below
	only has to state what makes it different.
]=]
type CrateBase = {
	Speed: number,
	Health: number,
	-- Awarded on any player kill, whatever the kind.
	XPReward: number?,
}

--- Threatens the base: reaching the end of the lane costs health. Carries no reward.
export type DamageCrateEntry = CrateBase & {
	Kind: "Damage",
	Damage: number,
}

--- Drops a lootbox (a key into Indexes/LootCrates) on a player kill. Harmless if leaked.
export type LootCrateEntry = CrateBase & {
	Kind: "Loot",
	LootCrate: string,
}

--- Rolls currency on a player kill. Harmless if leaked.
export type CurrencyCrateEntry = CrateBase & {
	Kind: "Currency",
	CurrencyDrops: { CurrencyReplication.CurrencyDrop },
}

--[=[
	A crate is exactly ONE of the three variants, discriminated by Kind. This is a union
	rather than one type with three optional fields, because optional fields would let a
	Damage crate also carry a LootCrate, a state the game has no meaning for.
]=]
export type CrateEntry = DamageCrateEntry | LootCrateEntry | CurrencyCrateEntry

local Crates: { [string]: CrateEntry } = {
	-- ---- Kind "Damage": the crates that actually threaten the base ----

	BasicCrate = {
		Kind = "Damage",
		Speed = 8,
		Health = 100,
		Damage = 10,
		XPReward = 10,
	},

	FastCrate = {
		Kind = "Damage",
		Speed = 16,
		Health = 60,
		Damage = 8,
		XPReward = 12,
	},

	TankCrate = {
		Kind = "Damage",
		Speed = 5,
		Health = 400,
		Damage = 40,
		XPReward = 30,
	},

	MythicalCrate = {
		Kind = "Damage",
		Speed = 7,
		Health = 250,
		Damage = 25,
		XPReward = 50,
	},

	-- ---- Kind "Currency": bonus targets that pay out ----

	CoinCrate = {
		Kind = "Currency",
		Speed = 9,
		Health = 120,
		CurrencyDrops = {
			{ Currency = "Coins", Chance = 1, Amount = 20 },
		},
		XPReward = 8,
	},

	GemCrate = {
		Kind = "Currency",
		Speed = 11,
		Health = 180,
		CurrencyDrops = {
			{ Currency = "Gems", Chance = 1, Amount = 3 },
			{ Currency = "Coins", Chance = 0.5, Amount = 10 },
		},
		XPReward = 15,
	},

	-- ---- Kind "Loot": kill these to unlock weapons and robots ----

	CommonWeaponCrate = {
		Kind = "Loot",
		Speed = 7,
		Health = 200,
		LootCrate = "CommonWeaponCrate",
		XPReward = 20,
	},

	RareWeaponCrate = {
		Kind = "Loot",
		Speed = 6,
		Health = 350,
		LootCrate = "RareWeaponCrate",
		XPReward = 40,
	},

	CommonRobotCrate = {
		Kind = "Loot",
		Speed = 7,
		Health = 200,
		LootCrate = "CommonRobotCrate",
		XPReward = 20,
	},

	RareRobotCrate = {
		Kind = "Loot",
		Speed = 6,
		Health = 350,
		LootCrate = "RareRobotCrate",
		XPReward = 40,
	},
}

return Crates
