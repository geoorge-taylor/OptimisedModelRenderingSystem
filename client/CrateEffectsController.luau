--!strict

-- Services
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

-- Classes
local Classes = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Classes")
local EffectPool = require(Classes:WaitForChild("EffectPool"))
local EffectsUtil = require(Classes:WaitForChild("EffectsUtil"))

-- Other controllers
local Controllers = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Controllers")
local SoundController = require(Controllers:WaitForChild("SoundController"))

-- Data
local PotionIndex = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Data"):WaitForChild("Indexes"):WaitForChild("Potions"))

-- Workspace
local EffectsFolder = Workspace:WaitForChild("Effects")

local HIT_SOUND_ID = "rbxassetid://122868316202433"
local DESTROY_SOUND_ID = "rbxassetid://87707253528917"

local HIT_SOUND_START_OFFSET = 0
local DESTROY_SOUND_START_OFFSET = 0

local HIGHLIGHT_FILL_TRANSPARENCY = 0.7
local HIGHLIGHT_OUTLINE_TRANSPARENCY = 0.3
local HIGHLIGHT_FADE_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local DUST_LIFETIME = 2
local DUST_EMIT_COUNT = 25

local DAMAGE_START_HEIGHT = 2
local DAMAGE_RISE_HEIGHT = 2.5
local DAMAGE_FALL_DEPTH = 1.5
local DAMAGE_ARC_MIN_DISTANCE = 1.5
local DAMAGE_ARC_MAX_DISTANCE = 3
local DAMAGE_RISE_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local DAMAGE_FALL_INFO = TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local CRIT_COLOR = Color3.fromRGB(255, 221, 51)
local CRIT_SCALE = 1.4

local DAMAGE_PREWARM = 12
local DUST_PREWARM = 6

--- A crate's live highlight and the single fade tween that drives it. The tween is
--- built with the highlight and replayed on each hit rather than rebuilt.
type HighlightEntry = {
	Highlight: Highlight,
	Tween: Tween,
}

type CrateEffectsControllerProperties = {
	_damagePool: EffectPool.EffectPool,
	_dustPool: EffectPool.EffectPool,
	_highlights: { [Model]: HighlightEntry },
	_damageBaseSize: UDim2,
	_damageNormalColor: Color3,
	_auraPools: { [string]: EffectPool.EffectPool },
	_auras: { [Model]: { [string]: Instance } },
	_fadeTweens: { [Instance]: Tween },
}

local CrateEffectsController = {}
CrateEffectsController.__index = CrateEffectsController

export type CrateEffectsController = typeof(setmetatable({} :: CrateEffectsControllerProperties, CrateEffectsController))

--[=[
	Returns a UDim2 with every component scaled by a factor.
	@param size UDim2 -- The size to scale.
	@param factor number -- The scale factor.
	@return UDim2 -- The scaled size.
]=]
local function scaleUDim2(size: UDim2, factor: number): UDim2
	return UDim2.new(size.X.Scale * factor, size.X.Offset * factor, size.Y.Scale * factor, size.Y.Offset * factor)
end

--[=[
	Returns a random horizontal offset: a random direction at a random distance
	within the arc range.
	@return Vector3 -- The horizontal (Y = 0) offset.
]=]
local function randomHorizontal(): Vector3
	local angle = math.random() * 2 * math.pi
	local distance = DAMAGE_ARC_MIN_DISTANCE + math.random() * (DAMAGE_ARC_MAX_DISTANCE - DAMAGE_ARC_MIN_DISTANCE)
	return Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
end

--[=[
	Builds the effect pools (from Assets/Effects templates), prewarms them, and
	captures the damage number's base size + normal colour from the template.
	@return () -- No return value.
]=]
function CrateEffectsController:Init()
	local self = self :: CrateEffectsController
	self._damagePool = EffectsUtil.poolFromTemplate("DamageNumber")
	self._dustPool = EffectsUtil.poolFromTemplate("CrateDust")
	self._damagePool:Prewarm(DAMAGE_PREWARM)
	self._dustPool:Prewarm(DUST_PREWARM)
	self._highlights = {}
	self._auraPools = {}
	self._auras = {}
	self._fadeTweens = {}

	local sample = self._damagePool:Acquire() :: BasePart
	local gui = sample:FindFirstChildWhichIsA("BillboardGui") :: BillboardGui
	self._damageBaseSize = gui.Size
	local label = gui:FindFirstChildWhichIsA("TextLabel")
	self._damageNormalColor = if label then label.TextColor3 else Color3.new(1, 1, 1)
	self._damagePool:Release(sample)
end

--[=[
	Registers this controller's sounds so their emitter pools and assets are warm
	before the first crate is hit.
	@return () -- No return value.
]=]
function CrateEffectsController:Start()
	local self = self :: CrateEffectsController
	SoundController:Preload(HIT_SOUND_ID, HIT_SOUND_START_OFFSET)
	SoundController:Preload(DESTROY_SOUND_ID, DESTROY_SOUND_START_OFFSET)
end

--[=[
	Plays the hit sound at a position (pooled + throttled via SoundController).
	@param atCFrame CFrame -- Where to play the sound.
	@return () -- No return value.
]=]
function CrateEffectsController:PlayHitSound(atCFrame: CFrame)
	local self = self :: CrateEffectsController
	SoundController:Play(HIT_SOUND_ID, atCFrame.Position)
end

--[=[
	Plays the destruction effect: a pooled dust burst plus the destroy sound.
	@param atCFrame CFrame -- Where to spawn the effect (the crate's last pose).
	@return () -- No return value.
]=]
function CrateEffectsController:PlayDestroyed(atCFrame: CFrame)
	local self = self :: CrateEffectsController
	SoundController:Play(DESTROY_SOUND_ID, atCFrame.Position)
	EffectsUtil.playPooled(self._dustPool, atCFrame, DUST_LIFETIME, function(part)
		local emitter = part:FindFirstChildWhichIsA("ParticleEmitter")
		if emitter then
			emitter:Emit(DUST_EMIT_COUNT)
		end
	end)
end

--[=[
	Spawns a pooled floating damage number that starts above the crate, arcs up and
	out in a random direction, then falls and fades before returning to the pool.
	Yellow + bigger on a crit.
	@param atCFrame CFrame -- The crate's pose to spawn above.
	@param damage number -- The damage amount to display.
	@param crit boolean? -- Whether this was a critical hit.
	@return () -- No return value.
]=]
function CrateEffectsController:PlayDamageNumber(atCFrame: CFrame, damage: number, crit: boolean?)
	local self = self :: CrateEffectsController
	local part = self._damagePool:Acquire() :: BasePart
	part.CFrame = CFrame.new(atCFrame.Position + Vector3.new(0, DAMAGE_START_HEIGHT, 0))
	part.Parent = EffectsFolder

	local gui = part:FindFirstChildWhichIsA("BillboardGui") :: BillboardGui
	gui.StudsOffsetWorldSpace = Vector3.zero
	gui.Size = if crit then scaleUDim2(self._damageBaseSize, CRIT_SCALE) else self._damageBaseSize

	local label = gui:FindFirstChildWhichIsA("TextLabel")
	local stroke
	if label then
		stroke = label:FindFirstChildWhichIsA("UIStroke")
		label.Text = tostring(damage)
		label.TextColor3 = if crit then CRIT_COLOR else self._damageNormalColor
		label.TextTransparency = 0
		if stroke then
			stroke.Transparency = 0
		end
	end

	-- Arc: rise to a peak offset half-way out + up, then fall to the full offset + down.
	-- The rise's Out easing (apex) + the fall's In easing (gravity) make the two legs read as one arc.
	local horizontal = randomHorizontal()
	local peakOffset = horizontal * 0.5 + Vector3.new(0, DAMAGE_RISE_HEIGHT, 0)
	local landOffset = horizontal + Vector3.new(0, -DAMAGE_FALL_DEPTH, 0)

	local rise = TweenService:Create(gui, DAMAGE_RISE_INFO, { StudsOffsetWorldSpace = peakOffset })
	rise.Completed:Connect(function()
		local fall = TweenService:Create(gui, DAMAGE_FALL_INFO, { StudsOffsetWorldSpace = landOffset })
		if label then
			self:_getFadeTween(label, "TextTransparency"):Play()
			if stroke then
				self:_getFadeTween(stroke, "Transparency"):Play()
			end
		end
		fall.Completed:Connect(function()
			self._damagePool:Release(part)
		end)
		fall:Play()
	end)
	rise:Play()
end

--[=[
	Shows (or refreshes) the hit highlight on a crate model, fading it out. Re-hitting
	mid-fade cancels and restores it. The highlight is owned here, not on the crate.
	@param model Model -- The crate model to highlight.
	@return () -- No return value.
]=]
function CrateEffectsController:PlayHighlight(model: Model)
	local self = self :: CrateEffectsController
	local existing = self._highlights[model]
	if existing then
		-- Re-hit mid-fade: restore the highlight and replay the same tween.
		existing.Tween:Cancel()
		existing.Highlight.FillTransparency = HIGHLIGHT_FILL_TRANSPARENCY
		existing.Highlight.OutlineTransparency = HIGHLIGHT_OUTLINE_TRANSPARENCY
		existing.Tween:Play()
		return
	end

	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = HIGHLIGHT_FILL_TRANSPARENCY
	highlight.OutlineTransparency = HIGHLIGHT_OUTLINE_TRANSPARENCY
	highlight.Adornee = model
	highlight.Parent = model

	local tween = TweenService:Create(highlight, HIGHLIGHT_FADE_INFO, {
		FillTransparency = 1,
		OutlineTransparency = 1,
	})
	local entry: HighlightEntry = { Highlight = highlight, Tween = tween }
	self._highlights[model] = entry

	tween.Completed:Connect(function(state: Enum.PlaybackState)
		if state == Enum.PlaybackState.Completed and self._highlights[model] == entry then
			self:_destroyHighlight(model, entry)
		end
	end)
	tween:Play()
end

--[=[
	Removes a crate's highlight immediately (call when the crate despawns/pools).
	@param model Model -- The crate model whose highlight to clear.
	@return () -- No return value.
]=]
function CrateEffectsController:ClearHighlight(model: Model)
	local self = self :: CrateEffectsController
	local entry = self._highlights[model]
	if entry then
		self:_destroyHighlight(model, entry)
	end
end

--[=[
	Tears down a crate's highlight and its tween. Clears the map entry first, so the
	Cancel below cannot re-enter through the tween's own Completed handler.
	@param model Model -- The crate model the highlight belongs to.
	@param entry HighlightEntry -- The entry to destroy.
	@return () -- No return value.
]=]
function CrateEffectsController:_destroyHighlight(model: Model, entry: HighlightEntry)
	local self = self :: CrateEffectsController
	if self._highlights[model] == entry then
		self._highlights[model] = nil
	end
	entry.Tween:Cancel()
	entry.Tween:Destroy()
	entry.Highlight:Destroy()
end

--[=[
	Returns the cached fade-to-invisible tween for a pooled instance, building it on
	first use. The goal is constant and damage-number instances are pooled rather than
	destroyed, so this is one tween per instance for the session instead of a fresh
	Tween instance on every hit.
	@param target Instance -- The pooled label or stroke to fade.
	@param property string -- The transparency property to drive.
	@return Tween -- The reusable fade tween.
]=]
function CrateEffectsController:_getFadeTween(target: Instance, property: string): Tween
	local self = self :: CrateEffectsController
	local tween = self._fadeTweens[target]
	if not tween then
		tween = TweenService:Create(target, DAMAGE_FALL_INFO, { [property] = 1 })
		self._fadeTweens[target] = tween
	end
	return tween
end

--[=[
	Attaches a potion's aura particle to a crate model (idempotent per type).
	@param model Model -- The crate model.
	@param potionType string -- The active potion type.
	@return () -- No return value.
]=]
function CrateEffectsController:ApplyPotionAura(model: Model, potionType: string)
	local self = self :: CrateEffectsController
	local part = model.PrimaryPart
	if not part then
		return
	end
	local perModel = self._auras[model]
	if perModel and perModel[potionType] then
		return
	end

	local pool = self:_getAuraPool(potionType)
	if not pool then
		return
	end
	local aura = pool:Acquire()
	aura.Parent = part

	if not perModel then
		perModel = {}
		self._auras[model] = perModel
	end
	perModel[potionType] = aura
end

--[=[
	Removes a potion's aura from a crate model.
	@param model Model -- The crate model.
	@param potionType string -- The potion type to clear.
	@return () -- No return value.
]=]
function CrateEffectsController:ClearPotionAura(model: Model, potionType: string)
	local self = self :: CrateEffectsController
	local perModel = self._auras[model]
	if not perModel then
		return
	end
	local aura = perModel[potionType]
	if aura then
		self._auraPools[potionType]:Release(aura)
		perModel[potionType] = nil
	end
	if not next(perModel) then
		self._auras[model] = nil
	end
end

--[=[
	Removes every aura from a crate model (call when the crate despawns/pools).
	@param model Model -- The crate model.
	@return () -- No return value.
]=]
function CrateEffectsController:ClearAllAuras(model: Model)
	local self = self :: CrateEffectsController
	local perModel = self._auras[model]
	if not perModel then
		return
	end
	for potionType, aura in pairs(perModel) do
		self._auraPools[potionType]:Release(aura)
	end
	self._auras[model] = nil
end

--[=[
	Gets (or lazily creates) the aura emitter pool for a potion type.
	@param potionType string -- The potion type.
	@return EffectPool.EffectPool? -- The pool, or nil if the potion is unknown.
]=]
function CrateEffectsController:_getAuraPool(potionType: string): EffectPool.EffectPool?
	local self = self :: CrateEffectsController
	local pool = self._auraPools[potionType]
	if pool then
		return pool
	end
	local config = PotionIndex[potionType]
	if not config then
		return nil
	end
	pool = EffectsUtil.poolFromTemplate(config.AuraTemplate)
	self._auraPools[potionType] = pool
	return pool
end

return (CrateEffectsController :: any) :: CrateEffectsController
