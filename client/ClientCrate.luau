--!strict
-- Services
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

local DIRECTION_EPSILON = 1e-4
local TURN_RESPONSIVENESS = 12
local GROUND_HEIGHT = 1
local PATH_HEIGHT = 8
local SHAKE_DURATION = 0.6
local SHAKE_ANGLE = 0.25
local SHAKE_FREQUENCY = 9
local HEALTH_TWEEN_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

type CrateModel = Model & {
	CrateMesh: MeshPart & {
		Overhead: BillboardGui & {
			NameLabel: TextLabel,
			HealthBack: Frame & {
				HealthFront: Frame,
			},
		},
	},
}

type ClientCrateProperties = {
	Id: number,
	PlotId: string,
	CrateType: string,
	Model: CrateModel,
	Part: BasePart,
	FromPosition: Vector3,
	ToPosition: Vector3,
	CurrentPosition: Vector3,
	LastUpdateTime: number,
	_groundY: number,
	_lookDirection: Vector3,
	_shakeElapsed: number,
	_healthFront: GuiObject,
	_healthTween: Tween?,
}

local ClientCrate = {}
ClientCrate.__index = ClientCrate

export type ClientCrate = typeof(setmetatable({} :: ClientCrateProperties, ClientCrate))

--[=[
	Creates a client crate from its model and places it at the spawn position. The
	mesh is anchored, stamped with its crate id, and tagged "Crate".
	@param id number -- Network id (unique among live crates).
	@param plotId string -- Plot the crate belongs to.
	@param crateType string -- Crate type key.
	@param initialPosition Vector3 -- Spawn position from the server.
	@param model Model -- Model instance this crate renders through.
	@return ClientCrate -- The constructed client crate.
]=]
function ClientCrate.new(
	id: number,
	plotId: string,
	crateType: string,
	initialPosition: Vector3,
	model: Model
): ClientCrate

	local self = setmetatable({}, ClientCrate) :: ClientCrate
	self.Id = id
	self.PlotId = plotId
	self.CrateType = crateType
	self.Model = model :: CrateModel

	local part = self.Model.CrateMesh
	self.Model.PrimaryPart = part
	part.Anchored = true
	part:SetAttribute("CrateId", id)
	CollectionService:AddTag(part, "Crate")
	self.Part = part

	self._groundY = GROUND_HEIGHT + PATH_HEIGHT + part.Size.Y / 2
	self._lookDirection = part.CFrame.LookVector
	self.FromPosition = initialPosition
	self.ToPosition = initialPosition
	self.CurrentPosition = initialPosition
	self.LastUpdateTime = os.clock()
	self._shakeElapsed = SHAKE_DURATION
	self._healthTween = nil

	self:_setupOverhead(crateType)
	part.CFrame = self:_buildCFrame(initialPosition)
	return self
end

--[=[
	Re-baselines interpolation when a new server snapshot arrives.
	@param position Vector3 -- Latest server-reported position to move toward.
	@return () -- No return value.
]=]
function ClientCrate:UpdateTarget(position: Vector3)
	local self = self :: ClientCrate
	self.FromPosition = self.CurrentPosition
	self.ToPosition = position
	self.LastUpdateTime = os.clock()
end

--[=[
	Smoothly tweens the health-bar front to a new fraction of full width.
	@param fraction number -- Remaining health as a 0..1 fraction.
	@return () -- No return value.
]=]
function ClientCrate:UpdateHealth(fraction: number)
	local self = self :: ClientCrate
	if self._healthTween then
		self._healthTween:Cancel()
	end

	local size = self._healthFront.Size
	local goal = UDim2.new(math.clamp(fraction, 0, 1), size.X.Offset, size.Y.Scale, size.Y.Offset)
	local tween = TweenService:Create(self._healthFront, HEALTH_TWEEN_INFO, { Size = goal })
	tween:Play()
	self._healthTween = tween
end

--[=[
	(Re)starts the hit shake: a decaying yaw wobble around the crate's Y axis.
	@return () -- No return value.
]=]
function ClientCrate:Shake()
	local self = self :: ClientCrate
	self._shakeElapsed = 0
end

--[=[
	Advances interpolation, facing and shake by one frame and returns the CFrame the
	part should be moved to (applied by the renderer via a batched BulkMoveTo).
	@param networkTickRate number -- Duration (seconds) of one server tick window.
	@param deltaTime number -- Seconds since the previous frame.
	@return CFrame -- The world CFrame the part should be moved to this frame.
]=]
function ClientCrate:StepInterpolation(networkTickRate: number, deltaTime: number): CFrame
	local self = self :: ClientCrate
	local alpha = math.clamp((os.clock() - self.LastUpdateTime) / networkTickRate, 0, 1)
	self.CurrentPosition = self.FromPosition:Lerp(self.ToPosition, alpha)

	self:_updateFacing(deltaTime)

	if self._shakeElapsed < SHAKE_DURATION then
		self._shakeElapsed += deltaTime
	end

	return self:_buildCFrame(self.CurrentPosition)
end

--[=[
	Resets transient render state and hands back the now-idle model for pooling.
	@return Model -- The model, ready to be pooled.
]=]
function ClientCrate:PrepareForPool(): Model
	local self = self :: ClientCrate
	if self._healthTween then
		self._healthTween:Cancel()
		self._healthTween = nil
	end
	self._shakeElapsed = SHAKE_DURATION
	return self.Model
end

--[=[
	Fully tears the crate down, destroying its model.
	@return () -- No return value.
]=]
function ClientCrate:Destroy()
	local self = self :: ClientCrate
	self.Model:Destroy()
end

--[=[
	Builds the world CFrame for a position: oriented along travel, with any active
	hit shake folded in as a decaying sine yaw around Y.
	@param position Vector3 -- Interpolated world-space position.
	@return CFrame -- Travel-facing (and possibly wobbling) CFrame for the part.
]=]
function ClientCrate:_buildCFrame(position: Vector3): CFrame
	local self = self :: ClientCrate
	local grounded = Vector3.new(position.X, self._groundY, position.Z)
	local cframe = CFrame.lookAt(grounded, grounded + self._lookDirection)

	if self._shakeElapsed < SHAKE_DURATION then
		local t = self._shakeElapsed
		local envelope = 1 - t / SHAKE_DURATION
		local angle = SHAKE_ANGLE * envelope * math.sin(2 * math.pi * SHAKE_FREQUENCY * t)
		cframe *= CFrame.fromAxisAngle(Vector3.yAxis, angle)
	end

	return cframe
end

--[=[
	Eases the stored look direction toward the current horizontal travel direction.
	@param deltaTime number -- Seconds since the previous frame.
	@return () -- No return value.
]=]
function ClientCrate:_updateFacing(deltaTime: number)
	local self = self :: ClientCrate
	local travel = self.ToPosition - self.FromPosition
	local flat = Vector3.new(travel.X, 0, travel.Z)
	if flat.Magnitude <= DIRECTION_EPSILON then
		return
	end

	local desired = flat.Unit
	local turnAlpha = 1 - math.exp(-TURN_RESPONSIVENESS * deltaTime)
	local blended = self._lookDirection:Lerp(desired, turnAlpha)
	if blended.Magnitude > DIRECTION_EPSILON then
		self._lookDirection = blended.Unit
	end
end

--[=[
	Sets the crate's name and caches the health-bar front, resetting it to full
	(important for a pooled model that may carry an old bar). Uses dot-access on the
	guaranteed model shape.
	@param crateType string -- Name to display.
	@return () -- No return value.
]=]
function ClientCrate:_setupOverhead(crateType: string)
	local self = self :: ClientCrate
	local overhead = self.Model.CrateMesh.Overhead
	overhead.NameLabel.Text = crateType

	local healthFront = overhead.HealthBack.HealthFront
	self._healthFront = healthFront
	local size = healthFront.Size
	healthFront.Size = UDim2.new(1, size.X.Offset, size.Y.Scale, size.Y.Offset)
end

return ClientCrate
