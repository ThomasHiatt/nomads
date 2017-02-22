local RandomFloat = import('/lua/utilities.lua').GetRandomFloat
local NomadsEffectUtil = import('/lua/nomadseffectutilities.lua')
local NomadsEffectTemplate = import('/lua/nomadseffecttemplate.lua')
local AIUtils = import('/lua/ai/aiutilities.lua')
local Buff = import('/lua/sim/Buff.lua')
local Utils = import('/lua/utilities.lua')
local Entity = import('/lua/sim/Entity.lua').Entity


-- ================================================================================================================
-- Bombard mode stuff
-- ================================================================================================================

function AddBombardModeToUnit(SuperClass)
    return Class(SuperClass) {

        HasBombardModeAbility = true,

        OnStopBeingBuilt = function(self, builder, layer)
            SuperClass.OnStopBeingBuilt(self, builder, layer)

            self.BombardmentMode = false

            -- disable weapons that shouldn't be disabled at this time.
            for i = 1, self:GetWeaponCount() do
                local wep = self:GetWeapon(i)
                local bp = wep:GetBlueprint()
                if (bp.BombardDisable and self.BombardmentMode) or (bp.BombardEnable and not self.BombardmentMode) then
                    self:SetWeaponEnabledByLabel( bp.Label, false )
                end
            end
        end,

        OnBombardmentModeChanged = function( self, enabled, changedByTransport )
            SuperClass.OnBombardmentModeChanged( self, enabled, changedByTransport )
        end,

        OnAttachedToTransport = function(self, transport, transportBone)
            self:SetBombardmentMode(false, true)
            SuperClass.OnAttachedToTransport(self, transport, transportBone)
        end,

        OnDetachedFromTransport = function(self, transport, transportBone)
            SuperClass.OnDetachedFromTransport(self, transport, transportBone)
            self:SetBombardmentMode(false, true)
        end,

        SetBombardmentMode = function(self, enable, changedByTransport)

            enable = (enable == true)  -- making sure enable is a boolean
            local prevState = self.BombardmentMode

            if enable ~= prevState then

                local unitBp = self:GetBlueprint()
                local BuffName = unitBp.Abilities.BombardMode.Buff or 'BombardMode'
                if enable then
                    Buff.ApplyBuff(self, BuffName)    -- bonuses for ROF, range, etc. are handled via a unit buff
                else
                    Buff.RemoveBuff(self, BuffName)
                end

                -- go through all weapons and see if they need bombardment mode specific actions
                for k, bp in unitBp.Weapon do

                    if bp.BombardDisable then
                        self:SetWeaponEnabledByLabel( bp.Label, not enable )

                    else
                        if bp.BombardEnable then
                            self:SetWeaponEnabledByLabel( bp.Label, enable )
                        end

                        if bp.Turreted and bp.BombardSwingTurret and not bp.DummyWeapon then
                            if bp.TurretBoneYaw and (not bp.BombardTurretRotationSpeed or bp.BombardTurretRotationSpeed > 0) and (not bp.BombardTurretYawRange or bp.BombardTurretYawRange > 0) then
                                if enable then
                                    self:StartRotatingWeaponTurret( bp.Label )
                                else
                                    self:StopRotatingWeaponTurret( bp.Label )
                                end
                            end
                        end
                    end

                    local wep = self:GetWeaponByLabel( bp.Label )
                    if wep.OnBombardmentModeChanged then
                        wep:OnBombardmentModeChanged( enable, changedByTransport or false )
                    end
                end

                self.BombardmentMode = enable

                self:OnBombardmentModeChanged( enable, changedByTransport or false )
            end
        end,

        StartRotatingWeaponTurret = function(self, label)
            -- start turret rotation

            -- this is a local function that does the rotating of the turret
            local RotationThread = function(self, label)

                local turret = self:GetWeaponByLabel( label )
                local bp = turret:GetBlueprint()

                -- kill old rotator if any. Also create a warning since this should not be normal behaviour.
                if self.TurretRotators and self.TurretRotators[ label ] then
                    WARN('Bombardment mode: This turret already has a rotator! Overriding it. Unit = '..repr(self:GetUnitId())..' turret = '..repr(label))
                    self.TurretRotators[ label ]:Destroy()
                elseif not self.TurretRotators then
                    self.TurretRotators = {}
                end

                -- set up new turret rotator
                local MaxYaw = bp.BombardTurretYawRange or math.ceil( bp.TurretYawRange * 0.08 )
                local speed = bp.BombardTurretRotationSpeed or bp.RateOfFire * 8
                local rotator = CreateRotator( self, bp.TurretBoneYaw, 'y' ):SetSpeed( speed ) :SetPrecedence( 25 )
                self.Trash:Add( rotator )
                self.TurretRotators[ label ] = rotator

                -- keep spinning the turret.
                -- bombardment mode is probably started on a group of units at once. To prevent all turrets rotating at the same
                -- time and hitting the same area we start with a random goal and direction so the turrets of all participating
                -- units spread their fire nicely.
                local direction = ( Random(0,1) * 2 ) - 1
                local goal = MaxYaw * direction * RandomFloat(0, 0.5)
                while self and not self:BeenDestroyed() and not self:IsDead() and self.BombardmentMode do
                    rotator:SetGoal( goal )
                    WaitFor(rotator)
                    WaitTicks(2)
                    direction = direction * -1
                    goal = MaxYaw * direction
                end
            end

            -- store the handles for all threats in a table for easy access
            if not self.TurretRotationHandles then
                self.TurretRotationHandles = {}
            end
            self.TurretRotationHandles[ label ] = self:ForkThread( RotationThread, label )
        end,

        StopRotatingWeaponTurret = function(self, label)
            -- stop turret rotation
            if self.TurretRotators[ label ] then
                KillThread( self.TurretRotationHandles[ label ] )
                self.TurretRotators[ label ]:Destroy()
                self.TurretRotators[ label ] = nil
            end
        end,
    }
end

-- ================================================================================================================
-- RADAR OVERCHARGE
-- ================================================================================================================

function AddIntelOvercharge(SuperClass)
    return Class(SuperClass) {

        OverchargeFxBone = 0,  -- bone used for overcharge and overcharge recovery effects. Also for charging effects if that bone isn't set (see next line)
        OverchargeChargingFxBone = nil,  -- if set this bone is used to play charging effects on
        OverchargeExplosionFxBone = 0, -- bone for the explosion effect played when the unit is destroyed while boosting radar

        OverchargeFx = {},
        OverchargeRecoveryFx = {},
        OverchargeChargingFx = {},
        OverchargeExplosionFx = {},
        OverchargeFxScale = 1,
        OverchargeRecoveryFxScale = 1,
        OverchargeChargingFxScale = 1,
        OverchargeExplosionFxScale = 1,

        OnCreate = function(self)
            SuperClass.OnCreate(self)
            self.IntelOverchargeEffects = TrashBag()
            self.IntelOverchargeRecoveryEffects = TrashBag()
            self.IntelOverchargeChargingEffects = TrashBag()
            self.IntelOverchargeExplosionEffects = TrashBag()
            self.IntelOverChargeChargingEmitters = {}
            self.IntelOverchargeInRecoveryTime = false
            self.IsIntelOverchargeChargingUp = false
        end,

        DoTakeDamage = function(self, instigator, amount, vector, damageType)
            if self.IsIntelOvercharging then
                amount = amount * (self:GetBlueprint().Intel.OverchargeDamageMulti or 1)
            end
            return SuperClass.DoTakeDamage(self, instigator, amount, vector, damageType)
        end,

        OnKilled = function(self, instigator, type, overkillRatio)
            self:DestroyIntelOverchargeEffects()
            self:DestroyIntelOverchargeRecoveryEffects()
            self:DestroyIntelOverchargeChargingEffects()
            self:FireIntelOverchargeDeathWeapon()
            return SuperClass.OnKilled(self, instigator, type, overkillRatio)
        end,

        OnDestroy = function(self)
            self:DestroyIntelOverchargeEffects()
            self:DestroyIntelOverchargeRecoveryEffects()
            self:DestroyIntelOverchargeChargingEffects()
            SuperClass.OnDestroy(self)
        end,

        OnStunned = function(self, duration)
            SuperClass.OnStunned(self, duration)
            self:IntelOverchargeChargingCancelled()
        end,

        CanIntelOvercharge = function(self)
            return (not self.IntelOverchargeInRecoveryTime and not self.IsIntelOvercharging and not self.IsIntelOverchargeChargingUp and not self:IsDead() and not self:IsStunned())
        end,

        FireIntelOverchargeDeathWeapon = function(self)
            if self.IsIntelOvercharging then
                local bp, wbp = self:GetBlueprint().Weapon, false
                for k, wepBp in bp do
                    if wepBp.Label == 'IntelOverchargeDeathWeapon' then
                        wbp = bp[k]
                        break
                    end
                end
                if wbp then
                    -- play fx
                    self:PlayIntelOverchargeExplosionEffects()
                    -- do regular damage
                    DamageArea( self, self:GetPosition(), wbp.DamageRadius, wbp.Damage, wbp.DamageType, wbp.DamageFriendly, false )
                    -- Handling buffs (emp)
                    if wbp.Buffs then
                        for k, buffTable in wbp.Buffs do
                            self:AddBuff(buffTable)
                        end
                    end

                    -- Play weapon sound
                    local snd = wbp.Audio['Fire']
                    if snd then
                        self:PlaySound(snd)
                    end

                    return true
                end
            end
            return false
        end,

        IntelOverchargeBeginCharging = function(self)
            if not self.IntelOverchargeThreadHandle then
                self.IntelOverchargeThreadHandle = self:ForkThread( self.IntelOverchargeThread )
                AddVOUnitEvent(self, 'IntelBoostInitiated')
            end
        end,

        IntelOverchargeChargingCancelled = function(self)
            -- call to cancel intel overcharging. Only works if not in recovery time. Also removes an active energy constumption.
            if self.IntelOverchargeThreadHandle and not self.IntelOverchargeInRecoveryTime then

                KillThread( self.IntelOverchargeThreadHandle )
                self.IntelOverchargeThreadHandle = nil

                self:StopUnitAmbientSound('IntelOverchargeChargingLoop')
                self:PlayUnitSound('IntelOverchargeChargingStop')

                if self.IntelOverchargeEconDrain then
                    RemoveEconomyEvent(self, self.IntelOverchargeEconDrain)
                    self.IntelOverchargeEconDrain = nil
                end
                if self.IsIntelOvercharging then
                    self:OnIntelOverchargeCancelled()
                else
                    self:OnIntelOverchargeChargingCancelled()
                end

                self:DestroyIntelOverchargeEffects()
                self:DestroyIntelOverchargeChargingEffects()
            end
        end,

        IntelOverchargeThread = function(self)
            local bp = self:GetBlueprint()
            local OverchargeType = bp.Intel.OverchargeType or false
            if not OverchargeType then return false end

            local eCost = bp.Intel.OverchargeEnergyCost or 0
            local eCostPerSec = bp.Intel.OverchargeEnergyDrainPerSecond or 100
            local numEvents, fraction, time = 10, 0, 0

            self:SpecialAbilitySetAvailability(false)

            if eCost > 0 then    -- charging, only if there is an energy requirement specified

                self.IsIntelOverchargeChargingUp = true

                local eCostPerEvent = eCost / numEvents
                local t = (eCost / eCostPerSec) / numEvents

                self:PlayUnitSound('IntelOverchargeChargingStart')
                self:PlayUnitAmbientSound('IntelOverchargeChargingLoop')

                self:OnIntelOverchargeBeginCharging()
                self:OnIntelOverchargeCharging( fraction )

                while self and fraction <= 1 do
                    self.IntelOverchargeEconDrain = CreateEconomyEvent(self, eCostPerEvent, 0, t)
                    self:UpdateConsumptionValues()
                    WaitFor(self.IntelOverchargeEconDrain)
                    fraction = fraction + (1 / numEvents)
                    self:OnIntelOverchargeCharging( fraction )
                    RemoveEconomyEvent(self, self.IntelOverchargeEconDrain)
                end

                self:StopUnitAmbientSound('IntelOverchargeChargingLoop')
                self:PlayUnitSound('IntelOverchargeChargingStop')

                self.IsIntelOverchargeChargingUp = false
                self.IntelOverchargeEconDrain = nil
            else
                self:OnIntelOverchargeCharging(1)
            end

            self:UpdateConsumptionValues()
            self:OnIntelOverchargeFinishedCharging()

            local BuffName = bp.Intel.OverchargeBuff or 'IntelOvercharge'
            local OverchargeEffectDelay = bp.Intel.OverchargeEffectDelay or 0
            local totalTime = bp.Intel.OverchargeTime or 5
            local recoverTime = bp.Intel.OverchargeRecoverTime or 0
            local timePerEvent = totalTime / numEvents
            fraction = 0

            self:PlayUnitSound('IntelOverchargeActivated')
            self:PlayUnitAmbientSound('IntelOverchargeActiveLoop')

            -- start the overcharge
            self.IsIntelOvercharging = true
            self:OnBeginIntelOvercharge()

            -- pre-activation delay
            if OverchargeEffectDelay > 0 then
                WaitSeconds( OverchargeEffectDelay )
            end

            -- activate increased intel
            Buff.ApplyBuff(self, BuffName)

            -- wait till we're out of juice
            self:OnIntelOverchargeActive( 0 )
            for i = 1, numEvents do
                time = math.min( totalTime, timePerEvent )
                totalTime = totalTime - time
                WaitSeconds( time + 0.1 )  -- + 0.1 to correct a 1 sec deviation (10 x 0.1)
                if i > 0 then
                    fraction = i / numEvents
                else
                    fraction = 0
                end
                self:OnIntelOverchargeActive( fraction )
            end

            Buff.RemoveBuff(self, BuffName, true)

            self:StopUnitAmbientSound('IntelOverchargeActiveLoop')
            self:PlayUnitSound('IntelOverchargeStopped')

            -- revert to previous situation
            self.IsIntelOvercharging = false
            self:OnFinishedIntelOvercharge()

            -- recovery time if requested
            if recoverTime > 0 then
                self.IntelOverchargeInRecoveryTime = true
                self:DisableUnitIntel('recover', 'Radar')
                self:DisableUnitIntel('recover', 'Sonar')
                self:OnBeginIntelOverchargeRecovery()
                WaitSeconds( recoverTime )
                self.IntelOverchargeInRecoveryTime = false
                self:EnableUnitIntel('recover', 'Radar')
                self:EnableUnitIntel('recover', 'Sonar')
            end

            self:OnFinishedIntelOverchargeRecovery()

            self:SpecialAbilitySetAvailability(true)
        end,

        OnBeginIntelOvercharge = function(self)
            self:DestroyIdleEffects()  -- removed the radar effect, the lines coming from the antennae
            self:PlayIntelOverchargeEffects()
        end,

        OnIntelOverchargeActive = function(self, fraction)
        end,

        OnFinishedIntelOvercharge = function(self)
            self:DestroyIntelOverchargeEffects()
            local recoveryTime = self:GetBlueprint().Intel.OverchargeRecoverTime or 0
            if recoveryTime <= 0 then
                self:CreateIdleEffects()
                AddVOUnitEvent(self, 'IntelBoostReady')
            end
        end,

        OnIntelOverchargeCancelled = function(self)
            -- Fired when intel overcharging is cancelled after the initial charging is completed and the unit is already overcharging
            self:DestroyIntelOverchargeEffects()
            local recoveryTime = self:GetBlueprint().Intel.OverchargeRecoverTime or 0
            if recoveryTime <= 0 then
                self:CreateIdleEffects()
            end
        end,

        OnBeginIntelOverchargeRecovery = function(self)
            self:PlayIntelOverchargeRecoveryEffects()
        end,

        OnFinishedIntelOverchargeRecovery = function(self)
            self:DestroyIntelOverchargeRecoveryEffects()
            self:CreateIdleEffects()
            AddVOUnitEvent(self, 'IntelBoostReady')
        end,

        OnIntelOverchargeBeginCharging = function(self)
            self:PlayIntelOverchargeChargingEffects()
        end,

        OnIntelOverchargeCharging = function(self, fraction)
            local scale = (self.OverchargeChargingFxScale or 1) * math.max( 0.01, fraction )
            self:ScaleIntelOverchargeChargingEffects(scale)
        end,

        OnIntelOverchargeFinishedCharging = function(self)
            self:DestroyIntelOverchargeChargingEffects()
        end,

        OnIntelOverchargeChargingCancelled = function(self)
            -- Fired when intel overcharging is cancelled when still charging up
            self:DestroyIntelOverchargeChargingEffects()
        end,

        PlayIntelOverchargeEffects = function(self)
            local army, emit = self:GetArmy()
            for k, v in self.OverchargeFx do
                emit = CreateAttachedEmitter( self, self.OverchargeFxBone, army, v )
                emit:ScaleEmitter( self.OverchargeFxScale or 1 )
                self.IntelOverchargeEffects:Add( emit )
                self.Trash:Add( emit )
            end
        end,

        DestroyIntelOverchargeEffects = function(self)
            self.IntelOverchargeEffects:Destroy()
        end,

        PlayIntelOverchargeRecoveryEffects = function(self)
            local army, emit = self:GetArmy()
            for k, v in self.OverchargeRecoveryFx do
                emit = CreateAttachedEmitter( self, self.OverchargeFxBone, army, v )
                emit:ScaleEmitter( self.OverchargeRecoveryFxScale or 1 )
                self.IntelOverchargeRecoveryEffects:Add( emit )
                self.Trash:Add( emit )
            end
        end,

        DestroyIntelOverchargeRecoveryEffects = function(self)
            self.IntelOverchargeRecoveryEffects:Destroy()
        end,

        PlayIntelOverchargeChargingEffects = function(self)
            local army, emit = self:GetArmy()
            local bone = self.OverchargeChargingFxBone

            if not bone then self.OverchargeChargingFxBone = self.OverchargeFxBone end

            for k, v in self.OverchargeChargingFx do
                emit = CreateAttachedEmitter( self, bone, army, v )
                emit:ScaleEmitter( self.OverchargeChargingFxScale or 1 )
                table.insert( self.IntelOverChargeChargingEmitters, emit )
                self.IntelOverchargeChargingEffects:Add( emit )
                self.Trash:Add( emit )
            end
        end,

        ScaleIntelOverchargeChargingEffects = function(self, scale)
            for k, v in self.IntelOverChargeChargingEmitters do
                v:ScaleEmitter(scale)
            end
        end,

        DestroyIntelOverchargeChargingEffects = function(self)
            self.IntelOverchargeChargingEffects:Destroy()
        end,

        PlayIntelOverchargeExplosionEffects = function(self)
            local army, emit = self:GetArmy()
            for k, v in self.OverchargeExplosionFx do
                emit = CreateEmitterAtBone( self, self.OverchargeExplosionFxBone or self.OverchargeFxBone, army, v )
                emit:ScaleEmitter( self.OverchargeExplosionFxScale or 1 )
                self.IntelOverchargeExplosionEffects:Add( emit )
            end
        end,

        DestroyIntelOverchargeExplosionEffects = function(self)
            self.IntelOverchargeExplosionEffects:Destroy()
        end,
    }
end

-- ================================================================================================================
-- Flares
-- ================================================================================================================

function AddFlares(SuperClass)
    SuperClass = import('/lua/proximitydetector.lua').ProximityDetector(SuperClass)
    return Class( SuperClass) {

        FlareBoneFx = NomadsEffectTemplate.FlareMuzzleFx,

        OnCreate = function(self)
            SuperClass.OnCreate( self )
            self.FlaresEnabled = false
            self.FlareFireTick = 0
            self.FlareTimeout = 0
            self.FlareBeSmart = false
        end,

        OnStopBeingBuilt = function(self, builder, layer)
            SuperClass.OnStopBeingBuilt(self, builder, layer)

            local bp = self:GetBlueprint().Defense.AntiMissileFlares
            self.FlareTimeout = math.ceil( 10 / (bp.RateOfFire or 1) )  -- 10 because we're using ticks here, not seconds
            self.FlareBeSmart = bp.BeSmart or false

            local radius = bp.Radius or 10
            local cat = bp.Category or 'ANTIAIR MISSILE'
            self:CreateProximityDetector('AAMdetect', radius, cat, false, false, true)
            self:SetFlaresEnabled(true)
        end,

        OnProximityAlert = function(self, other, radius, proxDetectorName)
            -- fires when an AA missile is close enough. Should fire flares.
            if proxDetectorName == 'AAMdetect' then
                if self:CheckShouldFire(other) then
                    self:FireFlares()
                end
            end
            SuperClass.OnProximityAlert(self, other, radius, proxDetectorName)
        end,

        CheckShouldFire = function(self, missile)
            if self.FlareBeSmart then
                if missile.IsBeingDeflectedByFlares then
                    return false
                end
            end
            return true
        end,

        FireFlares = function(self)
            if self:CanFireFlares() then
                self:ForkThread(self.FireFlaresThread)
            end
        end,

        FireFlaresThread = function(self)

            self.FlareFireTick = GetGameTick()

            local bp = self:GetBlueprint().Defense.AntiMissileFlares
            local flareBp = bp.ProjectileBlueprint or '/projectiles/NAAMissileFlare1/NAAMissileFlare1_proj.bp'
            local speed = bp.Speed or 10

            if bp.Bones then

                -- if a list of bones to fire a flare from is specified, do that.
                -- NumFlares indicates how many per bone. SalvoDelay is the time between salvos.
                local delay = bp.SalvoDelay or 5
                local numFlares = bp.NumFlares or 1
                local randomness = bp.FiringRandomness or 0.1
                local dx, dy, dz = 0, 0, 0
                for i = 1, numFlares do

                    for _, bone in bp.Bones do
                        dx, dy, dz = self:GetBoneDirection( bone )
                        dx = dx + RandomFloat( -randomness, randomness)
                        dy = dy + RandomFloat( -randomness, randomness)
                        dz = dz + RandomFloat( -randomness, randomness)
                        local proj = self:CreateProjectileAtBone( flareBp, bone )
                        proj:SetVelocity( dx, dy, dz )
                        proj:SetVelocity( speed )
                        self:OnFlareFiredFromBone(bone, proj, i)
                    end

                    self:PlayFlareFireEffects(bp.Bones)
                    self:OnFlareSalvoFired(i)

                    if i < numFlares and delay > 0 then
                        WaitTicks( delay )
                    end
                end

            elseif bp.Bone then

                -- if just one bone is specified fire flares in all directions, away from the bone
                local numFlares = bp.NumFlares or 3
                local bone = bp.Bone or 0
                local angle = (2*math.pi) / numFlares
                local angleVariation = angle / numFlares
                local angleInitial = self:GetHeading()
                local x, y, z = 0, 0, 0
                for i = 1, numFlares do
                    x = math.sin( angleInitial + ((i-1)*angle) + RandomFloat(-angleVariation, angleVariation) )
                    z = math.cos( angleInitial + ((i-1)*angle) + RandomFloat(-angleVariation, angleVariation) )
                    local proj = self:CreateProjectile( flareBp, 0, 0, 0, x, y, z)
                    if bone ~= 0 then
                        proj:SetPosition( self:GetPosition( bone ), true )
                    end
                    proj:SetVelocity( speed )
                    self:OnFlareFiredFromBone(bone, proj, 1)
                end
                self:PlayFlareFireEffects( {bone} )
                self:OnFlareSalvoFired(1)

            else
                WARN('FireFlares: No bone(s) specified to fire flares from. unit '..repr(self:GetUnitId()))
            end
        end,

        CanFireFlares = function(self)
            -- checks if we can fire the flares again. No if we just did it (flare launcher is reloading)
            if self.FlaresEnabled and not self:IsStunned() then
                local tick = GetGameTick()
                if tick >= (self.FlareFireTick + self.FlareTimeout) then
                    return true
                end
            end
            return false
        end,

        SetFlaresEnabled = function(self, enabled)
            self.FlaresEnabled = (enabled == true)
        end,

        GetFlaresEnabled = function(self)
            return self.FlaresEnabled
        end,

        PlayFlareFireEffects = function(self, muzzleBones)
            local army, emit = self:GetArmy()
            for k, v in self.FlareBoneFx do
                for _, bone in muzzleBones do
                    emit = CreateEmitterAtBone(self, bone, army, v)
                    self.Trash:Add(emit)
                end
            end
            self:PlayUnitSound('FlaresFired')
        end,

        OnFlareFiredFromBone = function(self, bone, flare, salvo)
        end,

        OnFlareSalvoFired = function(self, salvo)
        end,
    }
end

-- ================================================================================================================
-- Artillery Support
-- ================================================================================================================

--** Derive the supporting unit from this class
function SupportingArtilleryAbility(SuperClass)
    return Class(SuperClass) {

        SupportingNumArtilleryThisTick = 0,
        ArtillerySupportEnabled = true,
        ArtillerySupportFxBone = 0,

        EnableArtillerySupport = function(self, enable)
            self.ArtillerySupportEnabled = (enable == true)
        end,

        OnStartBeingBuilt = function(self, builder, layer)
            SuperClass.OnStartBeingBuilt(self, builder, layer)
            self:EnableArtillerySupport(false)
        end,

        OnStopBeingBuilt = function(self, builder, layer)
            SuperClass.OnStopBeingBuilt(self,builder,layer)
            self:EnableArtillerySupport(true)
        end,

        CheckCanSupportArtilleryForTarget = function(self, artillery, targetPos, target)
            -- return true or false to indicate whether we can help the artillery unit
            if not self.ArtillerySupportEnabled or self:IsStunned() then
                return false
            end

            local bp = self:GetBlueprint().Abilities.ArtillerySupport
            local max = bp.MaxSimultaniousArtillerySupport or 1
            local TarCat = bp.TargetCategory or categories.ALLUNITS
            local ArtCat = bp.ArtilleryCategory or categories.STRUCTURE
            local SupportGroundTargetting = (bp.SupportGroundTargetting == true)

            -- check num support restriction
            if max >= 0 and self.SupportingNumArtilleryThisTick >= max then
                return false
            end

            -- check target category restriction
            if target then
                if type(TarCat) == 'string' then
                    TarCat = ParseEntityCategory(TarCat)
                end
                if not EntityCategoryContains(TarCat, target) then
                    return false
                end
            elseif not SupportGroundTargetting then
                return false
            end

            return true
        end,

        OnSupportingArtillery = function(self, artillery, targetPos, target)

            local bp = self:GetBlueprint().Abilities.ArtillerySupport
            local MaxSimultaniousArtillerySupport = bp.MaxSimultaniousArtillerySupport or 1

            if MaxSimultaniousArtillerySupport > 0 then
                local lockout = math.max( bp.LockoutDuration or 1, 0)
                if lockout > 0 then
                    self:IncSupportCounter()
                    self:ForkThread(   -- lower the support counter after the lockout duration in seconds
                        function(self, lockout)
                            WaitSeconds(lockout)
                            self:DecSupportCounter()
                        end,
                    lockout)
                end
            end

            self:PlayUnitSound( 'SupportingArtilleryPing' )
            self:PlaySupportedArtilleryAbilityEffects( targetPos )
            self:PlaySupportedArtilleryTargetPosEffects( targetPos )
        end,

        PlaySupportedArtilleryAbilityEffects = function(self, targetPos)
            -- create some effect for when supporting an artillery unit
            local army, emit = self:GetArmy()
            for k, v in NomadsEffectTemplate.ArtillerySupportActive do
                emit = CreateAttachedEmitter( self, self.ArtillerySupportFxBone, army, v )
            end
        end,

        PlaySupportedArtilleryTargetPosEffects = function(self, targetPos)
            -- create some effect at target position for when supporting an artillery unit
            local ent = Entity()
            Warp(ent, Vector(unpack(targetPos)))

            local army, emit = self:GetArmy()
            for k, v in NomadsEffectTemplate.ArtillerySupportAtTargetLocation do
                emit = CreateEmitterAtEntity(ent, army, v )
            end

            ent:Destroy()
        end,

        IncSupportCounter = function(self)
            self.SupportingNumArtilleryThisTick = self.SupportingNumArtilleryThisTick + 1
        end,

        DecSupportCounter = function(self)
            self.SupportingNumArtilleryThisTick = self.SupportingNumArtilleryThisTick - 1
        end,

        GetArtillerySupportRange = function(self)
            return self._ArtillerySupportRange or self:GetBlueprint().Abilities.ArtillerySupport.Range or 0
        end,

        SetArtillerySupportRange = function(self, value)
            local old = self:GetArtillerySupportRange()
            self._ArtillerySupportRange = value
            return old
        end,
    }
end

--** This class should be used to derive the artillery weapon from.
function SupportedArtilleryWeapon(SuperClass)
    return Class(SuperClass) {

        OnCreate = function(self)
            SuperClass.OnCreate(self)
            self.ArtillerySupportEnabled = true
            self.SupportingUnit = nil
            self.SupportedThisSalvo = false
        end,

        SetArtillerySupportEnabled = function(self, enable)
            self.ArtillerySupportEnabled = (enable == true)
        end,

        RackSalvoFiringState = State(SuperClass.RackSalvoFiringState) {
            Main = function(self)
                -- check for support
                if self.ArtillerySupportEnabled then
                    self.SupportingUnit = self:GetAnArtillerySupporter()
                    self.SupportedThisSalvo = (self.SupportingUnit ~= nil)
                    if self.SupportedThisSalvo then
                        self.SupportingUnit:OnSupportingArtillery( self.unit, self:GetCurrentTargetPos(), self:GetCurrentTarget() )
                        self.unit:OnWeaponSupported( self.SupportingUnit, self, self:GetCurrentTargetPos(), self:GetCurrentTarget() )
                    end
                else
                    self.SupportingUnit = nil
                    self.SupportedThisSalvo = false
                end
                --LOG('Salvo supported = '..repr(self.SupportedThisSalvo))
                SuperClass.RackSalvoFiringState.Main(self)
            end,
        },

        CreateProjectileAtMuzzle = function(self, muzzle)
            local proj
            if self.SupportedThisSalvo then
                local OrgFR, NewFR = self:MakeSupported()
                --LOG('Projectile supported. NewFR = '..repr(NewFR)..' OrgFR = '..repr(OrgFR))
                local proj = SuperClass.CreateProjectileAtMuzzle(self, muzzle)
                self:MakeUnsupported(OrgFR)
            else
                proj = SuperClass.CreateProjectileAtMuzzle(self, muzzle)
            end
            return proj
        end,

        GetAnArtillerySupporter = function(self)
            -- returns a unit that can support this weapon, or nil if none are found

            local PosIsOk = function(pos)
                -- this weird position checking is necessary to filter out some strange positions, don't remove!
                if pos and pos[1] and pos[2] and pos[3] and pos[1] + 1 > pos[1] and pos[2] + 1 > pos[2] and pos[3] + 1 > pos[3] then
                    return true
                end
                return false
            end

            local target = self:GetCurrentTarget()
            local targetPos = self:GetCurrentTargetPos()
            if not PosIsOk(targetPos) and target and target.GetPosition then
                targetPos = target:GetPosition()
            end

            if PosIsOk(targetPos) then
                local range, pos1, dist

                -- the next line effectively limits the ability range to 70.
                local SupportingUnits = AIUtils.GetOwnUnitsAroundPoint(self.unit:GetAIBrain(), categories.ARTILLERYSUPPORT, targetPos, 70)
                for k, unit in SupportingUnits do
                    range = unit:GetArtillerySupportRange() or 0
                    if not unit:IsDead() and range > 0 then
                        pos1 = unit:GetPosition()
                        dist = VDist2(pos1[1], pos1[3], targetPos[1], targetPos[3])
                        if dist <= range and unit:CheckCanSupportArtilleryForTarget(self.Owner, targetPos, target) then
                            return unit
                        end
                    end
                end
            end
            return nil
        end,

        GetSupportingUnit = function(self)
            return self.SupportingUnit
        end,

        MakeSupported = function(self)
            -- improve firing randomness. No need to use a buff here because we can get the firing randomness before improving and then
            -- restore it to what it was.
            local SupportedFiringRandomnessDivider = self:GetBlueprint().SupportedFiringRandomnessDivider or 2
            local OrgFR = self:GetFiringRandomness()
            local NewFR = 0
            if OrgFR > 0 and SupportedFiringRandomnessDivider > 0 then
                NewFR = OrgFR / SupportedFiringRandomnessDivider
            end
            self:SetFiringRandomness( NewFR )
            return OrgFR, NewFR
        end,

        MakeUnsupported = function(self, OrgFiringRandomness)
            self:SetFiringRandomness(OrgFiringRandomness)
        end,
    }
end

-- ================================================================================================================
-- Lights class stuff
-- ================================================================================================================

function AddLights(SuperClass)
    -- a quick way to add four different lighttypes to many bones
    return Class(SuperClass) {

        LightBones = nil,

        OnPreCreate = function(self)
            SuperClass.OnPreCreate(self)
            self.LightsBag = TrashBag()
        end,

        OnStopBeingBuilt = function(self, builder, layer)
            SuperClass.OnStopBeingBuilt(self, builder, layer)
            self:AddLights()
        end,

        OnKilled = function(self, instigator, type, overkillRatio)
            self:RemoveLights()
            SuperClass.OnKilled(self, instigator, type, overkillRatio)
        end,

        OnBombardmentModeChanged = function( self, enabled, changedByTransport )
            SuperClass.OnBombardmentModeChanged( self, enabled, changedByTransport )

            -- refresh lights
            self:AddLights()
        end,

        AddLights = function(self)
            -- adds light emitters to the light bones
            self:RemoveLights()
            if self.LightBones then
                local army, emit, templ = self:GetArmy(), nil, nil

                for i=1, table.getn(self.LightBones) do
                    if self.LightBones[i] then
                        for _, bone in self.LightBones[i] do
                            templ = self:GetLightTemplate(i)
                            for k, v in templ do
                                emit = CreateAttachedEmitter(self, bone, army, v)
                                self.LightsBag:Add( emit )
                                self.Trash:Add( emit )
                            end
                        end
                    end
                end
            else
                WARN('AddLights: No light emitter bones specified. '..repr(self:GetUnitId()))
            end
        end,

        GetLightTemplate = function(self, n)
            if self.BombardmentMode then
                return NomadsEffectTemplate['AntennaeLights_'..tostring(n)..'_Bombard']
            end
            return NomadsEffectTemplate['AntennaeLights'..tostring(n)]
        end,

        RemoveLights = function(self)
            if self.LightsBag then
                self.LightsBag:Destroy()
            end
        end,
    }
end

function AddNavalLights(SuperClass)
    -- a quick way to add lights on two antennae of most naval units
    SuperClass = AddLights(SuperClass)
    return Class(SuperClass) {

        LightBone_Left = nil,
        LightBone_Right = nil,

        OnStopBeingBuilt = function(self, builder, layer)
            SuperClass.OnStopBeingBuilt(self, builder, layer)
            if layer == 'Sub' or layer == 'Seabed' then
                self:RemoveLights()
            end
        end,

        OnLand = function(self)
            self:AddLights()
            return SuperClass.OnInWater(self)
        end,

        OnWater = function(self)
            self:AddLights()
            return SuperClass.OnInWater(self)
        end,

        OnInWater = function(self)
            self:RemoveLights()
            return SuperClass.OnInWater(self)
        end,

        OnMotionVertEventChange = function(self, new, old)
            SuperClass.OnMotionVertEventChange(self, new, old)
            local layer = self:GetCurrentLayer()
            if new == 'Down' and layer == 'Water' then
                self:RemoveLights()
            end
        end,

        AddLights = function(self)
            -- adds light emitters to the antennae bones
            self:RemoveLights()
            if self.LightBone_Left and self.LightBone_Right then
                local army, templ, emit = self:GetArmy(), self:GetLightTemplate(0), nil
                for k, v in templ do
                    emit = CreateAttachedEmitter(self, self.LightBone_Left, army, v)
                    self.Trash:Add( emit )
                    self.LightsBag:Add( emit )
                end
                templ = self:GetLightTemplate(1)
                for k, v in templ do
                    emit = CreateAttachedEmitter(self, self.LightBone_Right, army, v)
                    self.Trash:Add( emit )
                    self.LightsBag:Add( emit )
                end
            else
                WARN('AddLights: No light emitter bones specified. '..repr(self:GetUnitId()))
            end
        end,

        GetLightTemplate = function(self, n)
            if self.BombardmentMode then
                if n == 0 then
                    return NomadsEffectTemplate.NavalAntennaeLights_Left_Bombard
                end
                return NomadsEffectTemplate.NavalAntennaeLights_Right_Bombard
            end
            if n == 0 then
                return NomadsEffectTemplate.NavalAntennaeLights_Left
            end
            return NomadsEffectTemplate.NavalAntennaeLights_Right
        end,
    }
end

-- ================================================================================================================
-- RAPID REPAIR
-- ================================================================================================================

function AddRapidRepair(SuperClass)
    return Class(SuperClass) {

        OnCreate = function(self)
            SuperClass.OnCreate(self)
            self.RapidRepairFxBag = TrashBag()
            self.RapidRepairParams = {}
            self.RapidRepairCounter = -1
        end,

        DoTakeDamage = function(self, instigator, amount, vector, damageType)
            SuperClass.DoTakeDamage(self, instigator, amount, vector, damageType)
            self:DelayRapidRepair()
        end,

        OnStartRapidRepairing = function(self)
            -- when the unit starts to be repaired
        end,

        OnFinishedRapidRepairing = function(self)
            -- when the unit is fully repaired
        end,

        OnRapidRepairingInterrupted = function(self)
            -- when the unit is being repaired but receives damage or fires a weapon
        end,

        OnRapidRepairingDelayed = function(self)
            -- when the unitis NOT being repaired and receives damage or fires a weapon
        end,

        SetRapidRepairParams = function(self, buffName, repairDelay, WeaponFireInterrupts)
            self.RapidRepairParams = {
                buffName = buffName,
                repairDelay = repairDelay or 30,
            }

            if WeaponFireInterrupts ~= nil then
                local nwep, wep = self:GetWeaponCount()
                for i=1, nwep do
                    wep = self:GetWeapon(i)
                    wep.DelaysRapidRepair = WeaponFireInterrupts
                end
            end
        end,

        RapidRepairIsRepairing = function(self)
            -- says whether we're repairing at this moment
            if self.RapidRepairProcessThreadHandle then
                return true
            end
            return false
        end,

        EnableRapidRepair = function(self, enable)
            -- enables or disables the rapid repair process (this is something else than stopping it)
            if enable then
                self.RapidRepairCounter = 0
                if not self.RapidRepairThreadHandle then
                    self.RapidRepairThreadHandle = self:ForkThread( self.RapidRepairThread )
                end
            else
                self.RapidRepairCounter = -1
                self:RapidRepairProcessStop()
                if self.RapidRepairThreadHandle then
                    KillThread( self.RapidRepairThreadHandle )
                    self.RapidRepairThreadHandle = nil
                end
                local buffName = self:GetRapidRepairParam('buffName')
                Buff.RemoveBuff( self, buffName )
            end
        end,

        GetRapidRepairParam = function(self, param)
            if self.RapidRepairParams[ param ] then
                return self.RapidRepairParams[ param ]
            end
        end,

        DelayRapidRepair = function(self)
            -- used to stop and reset the rapid repair process. Should be called if unit is damaged or fires a weapon.
            --LOG('*DEBUG: DelayRapidRepair')
            local repairing = self:RapidRepairIsRepairing()
            self.RapidRepairCounter = math.min( 0, self.RapidRepairCounter )
            self:RapidRepairProcessStop()
            if not repairing then
                self:OnRapidRepairingDelayed()
            end
        end,

        RapidRepairThread = function(self)
            -- counts up and starts the repair process when enough time passed
            local bp = self:GetBlueprint()
            local delay = self:GetRapidRepairParam('repairDelay')

            while not self:IsDead() and self.RapidRepairCounter >= 0 do

                -- if the timer isn't expired yet, add one to it
                if self.RapidRepairCounter < delay then
                    self.RapidRepairCounter = self.RapidRepairCounter + 1

                -- if the counter is expired but we're not repairing, start repairing
                elseif not self:RapidRepairIsRepairing() and self:GetHealth() < self:GetMaxHealth() then
                    self.RapidRepairProcessThreadHandle = self:ForkThread( self.RapidRepairProcessThread )

                end
                WaitSeconds(1)
            end
        end,

        RapidRepairProcessThread = function(self)

            local buffName = self:GetRapidRepairParam('buffName')

            -- start self repair effects
            self.RapidRepairFxBag:Add( ForkThread( NomadsEffectUtil.CreateSelfRepairEffects, self, self.RapidRepairFxBag ) )
            Buff.ApplyBuff(self, buffName)

            self:OnStartRapidRepairing()

            -- the buff increases regen. Wait till we're done "repairing"
            while not self:IsDead() and self:GetHealth() < self:GetMaxHealth() and self.RapidRepairCounter > -1 and self.RapidRepairProcessThreadHandle do
                WaitTicks(1)
            end

            -- stop the repair effects
            if Buff.HasBuff( self, buffName ) then
                Buff.RemoveBuff( self, buffName )
            end
            self.RapidRepairFxBag:Destroy()

            self:OnFinishedRapidRepairing()
        end,

        RapidRepairProcessStop = function(self)
            if self.RapidRepairProcessThreadHandle then
                KillThread( self.RapidRepairProcessThreadHandle )
                self.RapidRepairProcessThreadHandle = nil

                -- since we just killed the thread that (also) remove the buff, do it here: stop the repair effects
                local buffName = self:GetRapidRepairParam('buffName')
                if Buff.HasBuff( self, buffName ) then
                    Buff.RemoveBuff( self, buffName )
                end

                self:OnRapidRepairingInterrupted()
            end
            self.RapidRepairFxBag:Destroy()
        end,
    }
end

function AddRapidRepairToWeapon(SuperClass)
    -- should be used for the units weapon classes
    return Class(SuperClass) {

        OnCreate = function(self)
            DelaysRapidRepair = true
            SuperClass.OnCreate(self)
        end,

        OnWeaponFired = function(self)
            SuperClass.OnWeaponFired(self)
            if self.DelaysRapidRepair then
                self.unit:DelayRapidRepair()
            end
        end,
    }
end

-- ================================================================================================================
-- ENHANCEMENT PRESET
-- ================================================================================================================
--Proper enhancement preset code was integrated in FAF with version 3629, so removing it here.
function AddEnhancementPresetHandling(SuperClass)
    return Class(SuperClass) {}
end
-- todo - remove this completely

-- ================================================================================================================
-- AKIMBO
-- ================================================================================================================

function AddAkimbo( SuperClass )
    return Class(SuperClass) {

        StopBeingBuiltEffects = function(self, builder, layer)
            SuperClass.StopBeingBuiltEffects(self, builder, layer)
            self.AkimboThreadHandle = self:ForkThread( self.AkimboThread )
        end,

        OnStunned = function(self, duration)
            SuperClass.OnStunned(self, duration)
            if self.TorsoRotManip then
                self.TorsoRotManip:SetGoal( self.TorsoRotManip:GetCurrentAngle() )
            end
            if self.HeadRotManip then
                self.HeadRotManip:SetGoal( self.HeadRotManip:GetCurrentAngle() )
            end
        end,

        AkimboThread = function(self)
            -- Keeps the head and torso rotated to the current target position.
            -- The SCU has 2 arms which can individually target enemies. They each have a limited firing arc (yaw) so it is possible that the
            -- arms have a target that's not within the firing arc. This script makes the torso rotate so that at least 1 arm can fire at it's
            -- target. It does it's best to also accomodate the second weapon (gattling) but if it's not possible, the second weapon is assigned
            -- the target of the first weapon.
            -- The head is rotated to face (1) the target of weapon 1, (2) the target of weapon 2, or (3) the movement destination.

            -- TODO: implement [1] support for weapon HeadingArc parameters, [2] non-zero-based default torso yaw (so that it's relaxed
            -- position is not rotation 0 but something else, specified in bp, [3] further optimizations (remove or combine calculations?), 
            -- [4] support for third and fourth weapon???

            -- local functions, used to make the code below more readable
            local GetWepTargetPos = function(wep)
                local wepTarget, wepTargetPos
                local target = wep:GetCurrentTarget()
                if target and target.GetPosition then
                    wepTargetPos = target:GetPosition()
                    wepTarget = target
                else
                    wepTargetPos = wep:GetCurrentTargetPos()
                    wepTarget = nil
                end
                return wepTargetPos, wepTarget
            end
            local GetTargetAngle = function(self, wepTargetPos, torsoDir)
                if wepTargetPos then
                    local unitPos = self:GetPosition()
                    local vect = Utils.NormalizeVector( Vector(wepTargetPos.x - unitPos.x, 0, wepTargetPos.z - unitPos.z) )
                    local angle = ( math.atan2(vect.x, vect.z ) - math.atan2( torsoDir.x, torsoDir.z ) ) * 180 / math.pi

                    if angle > 180 then angle = angle - 360
                    elseif angle < -180 then angle = angle + 360
                    end

                    return angle
                end
            end

            local unitDir, unitX, unitY, unitZ, torsoDir, torsoRot, torsoX, torsoY, torsoZ, headTargetPos, wep1Target, wep1TargetPos, wep2TargetPos, wep1CurTargetAngle, wep2CurTargetAngle, minTorsoRotLimit, maxTorsoRotLimit
            local headIntendRot, torsoIntendRot = 0, 0

            local bp = self:GetBlueprint().Display.AkimboControl
            local doHeadRotation = bp.Head or false
            local headBone = bp.HeadBone
            local headRotSpeed = bp.HeadYawSpeed or 50
            local headRotLimit = bp.HeadYawLimit or 25
            local torsoBone = bp.TorsoBone
            local torsoRotSpeed = bp.TorsoYawSpeed or 50
            local torsoRotLimit = bp.TorsoYawRange or 360
            local allowRetarget = bp.AllowRetargettingSecondWeapon or false

            local yawRangeMarginMulti = 1 - 0.05  -- 5% safety margin, decrease firing arc by this much to make sure we interact on time.

            local weps = {}
            weps[1] = self:GetWeaponByLabel( bp.FirstWeapon )
            weps[2] = self:GetWeaponByLabel( bp.SecondWeapon )
            if bp.ThirdWeapon then weps[3] = self:GetWeaponByLabel( bp.ThirdWeapon ) end
            if bp.FourthWeapon then weps[4] = self:GetWeaponByLabel( bp.FourthWeapon ) end
            if bp.FifthWeapon then weps[5] = self:GetWeaponByLabel( bp.FifthWeapon ) end
            if bp.SixthWeapon then weps[6] = self:GetWeaponByLabel( bp.SixthWeapon ) end

            local wepYawRangeMin = {}
            local wepYawRangeMax = {}
            for k, wep in weps do
                local wepBp = wep:GetBlueprint()
                wepYawRangeMin[k] = wepBp.TurretYaw - (wepBp.TurretYawRange * yawRangeMarginMulti) + math.min(3, wepBp.TurretYawRange * yawRangeMarginMulti) -- second half of this line is also for safety
                wepYawRangeMax[k] = wepBp.TurretYaw + (wepBp.TurretYawRange * yawRangeMarginMulti) - math.min(3, wepBp.TurretYawRange * yawRangeMarginMulti) -- second half of this line is also for safety
            end

            local wepTargetPos = {}
            local wepCurTargetAngle = {}
            local PrimaryWeaponTarget = nil

--            local wep1 = self:GetWeaponByLabel( bp.FirstWeapon )
--            local wep1Bp = wep1:GetBlueprint()
--            local wep1YawRangeMin = wep1Bp.TurretYaw - (wep1Bp.TurretYawRange * yawRangeMarginMulti) + math.min(3, wep1Bp.TurretYawRange * yawRangeMarginMulti) -- second half of this line is also for safety
--            local wep1YawRangeMax = wep1Bp.TurretYaw + (wep1Bp.TurretYawRange * yawRangeMarginMulti) - math.min(3, wep1Bp.TurretYawRange * yawRangeMarginMulti) -- second half of this line is also for safety
--            local wep2 = self:GetWeaponByLabel( bp.SecondWeapon )  -- this weapon might be forced to retarget
--            local wep2Bp = wep2:GetBlueprint()
--            local wep2YawRangeMin = wep2Bp.TurretYaw - (wep2Bp.TurretYawRange * yawRangeMarginMulti) + math.min(3, wep2Bp.TurretYawRange * yawRangeMarginMulti) -- second half of this line is also for safety
--            local wep2YawRangeMax = wep2Bp.TurretYaw + (wep2Bp.TurretYawRange * yawRangeMarginMulti) - math.min(3, wep2Bp.TurretYawRange * yawRangeMarginMulti) -- second half of this line is also for safety

            local nav = self:GetNavigator()  -- can tell us where the unit is heading

            if doHeadRotation then
                self.HeadRotManip = CreateRotator(self, headBone, 'y', nil):SetCurrentAngle(0)
                self.Trash:Add(self.HeadRotManip)
            end
            self.TorsoRotManip = CreateRotator(self, torsoBone, 'y', nil):SetCurrentAngle(0)
            self.Trash:Add(self.TorsoRotManip)

            while not self:IsDead() do

                -- if we're EMP-ed then wait till we're no longer EMP-ed
                while self:IsStunned() do
                    WaitSeconds( 0.2 )
                end

                -- get torso orientations
                torsoX, torsoY, torsoZ = self:GetBoneDirection(torsoBone)
                torsoDir = Utils.NormalizeVector( Vector( torsoX, 0, torsoZ) )

                -- find current target for weapon 1. We mainly need the position of the target, but the target unit is stored in case we need to retarget wep 2
--                wep1TargetPos, wep1Target = GetWepTargetPos(wep1)
--                wep2TargetPos = GetWepTargetPos(wep2)
                local PrimaryWeaponTarget = nil
                local PrimaryWeaponKey = -1
                for k, wep in weps do
                    local pos, trgt = GetWepTargetPos(wep)
                    wepTargetPos[k] = pos
                    if not PrimaryWeaponTarget then
                        PrimaryWeaponTarget = trgt
                        PrimaryWeaponKey = k
                    end
                end

                -- determine angles of both weapons targets. The function returns nil when no target
                local NumWepWithCurTargetAngle = 0
                local CurTargetAngleSum = 0
                for k, wep in weps do
                    wepCurTargetAngle[k] = GetTargetAngle( self, wepTargetPos[k], torsoDir )
                    if wepCurTargetAngle[k] then
                        CurTargetAngleSum = CurTargetAngleSum + wepCurTargetAngle[k]
                        NumWepWithCurTargetAngle = NumWepWithCurTargetAngle + 1
                    end
                end

--                wep1CurTargetAngle = GetTargetAngle( self, wep1TargetPos, torsoDir )
--                wep2CurTargetAngle = GetTargetAngle( self, wep2TargetPos, torsoDir )

                -- if one weapon doesn't have a current target angle then take the one from the other weapon
--                if wep1CurTargetAngle == nil and wep2CurTargetAngle ~= nil then
--                    wep1CurTargetAngle = wep2CurTargetAngle
--                elseif wep2CurTargetAngle == nil and wep1CurTargetAngle ~= nil then
--                    wep2CurTargetAngle = wep1CurTargetAngle
--                end

                -- now find the best rotation for the torso. Ideally the torso rotates so it's in between both targets. In case this is not
                -- possible because the targets too far apart then weapon 1 is prefered and weapon 2 gets the target of weapon 1. If there's just
                -- 1 target then it's easy, and if there is no target at all then just rotate to normal position.
--                if wep2CurTargetAngle == nil and wep1CurTargetAngle == nil then
                if NumWepWithCurTargetAngle == 0 then
                    torsoIntendRot = 0  -- no target means no rotation needed

                else

                    -- get torso and main bone orientations. MOved here for efficiency reason from a few lines up, we only need it here
                    unitX, unitY, unitZ = self:GetBoneDirection(0)
                    unitDir = Utils.NormalizeVector( Vector( unitX, 0, unitZ) )
                    torsoRot = ( math.atan2( torsoDir.x, torsoDir.z ) - math.atan2( unitDir.x, unitDir.z ) ) * 180 / math.pi

                    if CurTargetAngleSum == 0 then  -- avoid dividing by 0 (see the else)
                        torsoIntendRot = 0  -- if the target of both weapons is direct forward then no need for a rotation adjustment 

                    else

                        -- calculate current torso rotation limits, the torso cannot rotate beyond these values
                        minTorsoRotLimit = -torsoRotLimit - torsoRot
                        maxTorsoRotLimit = torsoRotLimit - torsoRot

                        -- the best angle is calculated here. Works for 1 target aswell since both have the same angle. The max-ing and min-ing is
                        -- for limiting torso rotation (if so intended)
                        torsoIntendRot = math.max( minTorsoRotLimit, math.min( maxTorsoRotLimit, CurTargetAngleSum / NumWepWithCurTargetAngle ))

--                        torsoIntendRot = math.max( minTorsoRotLimit, math.min( maxTorsoRotLimit, (wep1CurTargetAngle + wep2CurTargetAngle) / 2))

                        -- Ok, so now we have determined the best ideal angle for the torso. Now checking if it allows both weapons to hit target. If
                        -- not then adjust the angle.
                        -- First weapon 1. If it can't hit target then wep 2 will have to retarget.

                        for k, wep in weps do

                            if not wepCurTargetAngle[k] then
                                continue

                            elseif (wepCurTargetAngle[k] - torsoIntendRot) <= wepYawRangeMin[k] then
                                -- wep 2 can't hit. Check if wep 2 can hit if torso rotates a bit more. If not, retarget or use best rotation possible
--                                local wep1YawRemaining = math.min( math.abs(torsoIntendRot + wep1YawRangeMin - wep1CurTargetAngle), math.abs(torsoIntendRot + wep1YawRangeMax - wep1CurTargetAngle) )
--                                local wep2YawNeeded = wep2CurTargetAngle - torsoIntendRot - wep2YawRangeMin
--                                if math.abs(wep2YawNeeded) < wep1YawRemaining then
--                                    torsoIntendRot = torsoIntendRot + wep2YawNeeded  -- rotate a bit more for wep 2
--                                    torsoIntendRot = math.max( minTorsoRotLimit, math.min( torsoIntendRot, maxTorsoRotLimit)) -- abide torso rotation limit
--                                elseif allowRetarget and wep1Target then  -- retarget wep 2, only if there is a target

                                if allowRetarget and PrimaryWeaponTarget then  -- retarget wep 2, only if there is a target
                                    wep:SetTargetEntity( PrimaryWeaponTarget )
                                    torsoIntendRot = wepCurTargetAngle[PrimaryWeaponKey]
                                    torsoIntendRot = math.max( minTorsoRotLimit, math.min( torsoIntendRot, maxTorsoRotLimit)) -- abide torso rotation limit
                                else  -- no valid target, at least let wep 1 fire. Rotate so target 1 is just in firing arc for wep 1
                                    torsoIntendRot = torsoIntendRot + (wepCurTargetAngle[PrimaryWeaponKey] - torsoIntendRot - wepYawRangeMin[PrimaryWeaponKey])  -- min!
                                    torsoIntendRot = math.max( minTorsoRotLimit, math.min( torsoIntendRot, maxTorsoRotLimit)) -- abide torso rotation limit
                                end

                            elseif (wepCurTargetAngle[k] - torsoIntendRot) >= wepYawRangeMax[k] then
                                -- wep 2 can't hit. Check if wep 2 can hit if torso rotates a bit more. If not, retarget or use best rotation possible
--                                local wep1YawRemaining = math.min( math.abs(torsoIntendRot + wep1YawRangeMin - wep1CurTargetAngle), math.abs(torsoIntendRot + wep1YawRangeMax - wep1CurTargetAngle) )
--                                local wep2YawNeeded = wep2CurTargetAngle - torsoIntendRot - wep2YawRangeMax
--                                if math.abs(wep2YawNeeded) < wep1YawRemaining then
--                                    torsoIntendRot = torsoIntendRot + wep2YawNeeded  -- rotate a bit more for wep 2
--                                    torsoIntendRot = math.max( minTorsoRotLimit, math.min( torsoIntendRot, maxTorsoRotLimit)) -- abide torso rotation limit
--                                elseif allowRetarget and wep1Target then  -- retarget wep 2, only if there is a target

                                if allowRetarget and PrimaryWeaponTarget then  -- retarget wep 2, only if there is a target
                                    wep:SetTargetEntity( PrimaryWeaponTarget )
                                    torsoIntendRot = wepCurTargetAngle[PrimaryWeaponKey]
                                    torsoIntendRot = math.max( minTorsoRotLimit, math.min( torsoIntendRot, maxTorsoRotLimit)) -- abide torso rotation limit
                                else  -- no valid target, at least let wep 1 fire. Rotate so target 1 is just in firing arc for wep 1
                                    torsoIntendRot = torsoIntendRot + (wepCurTargetAngle[PrimaryWeaponKey] - torsoIntendRot - wepYawRangeMax[PrimaryWeaponKey])  -- max!
                                    torsoIntendRot = math.max( minTorsoRotLimit, math.min( torsoIntendRot, maxTorsoRotLimit)) -- abide torso rotation limit
                                end
                            end

                        end



--                        if (wep1CurTargetAngle - torsoIntendRot) <= wep1YawRangeMin then
--                            -- weapon 1 can't hit target with new rotation - have weapon 2 also target weapon 1's target
--                            if allowRetarget and wep1Target then  -- if weapon 1 has a valid target have wep 2 also target that
--                                wep2:SetTargetEntity( wep1Target )
--                                torsoIntendRot = wep1CurTargetAngle
--                                torsoIntendRot = math.max( minTorsoRotLimit, math.min( torsoIntendRot, maxTorsoRotLimit)) -- abide torso rotation limit
--                            else  -- if no valid target then at least give wep 1 the room to fire. Rotate so target 1 is just in firing arc for wep 1
--                                torsoIntendRot = torsoIntendRot + (wep1CurTargetAngle - torsoIntendRot - wep1YawRangeMin)  -- min!
--                                torsoIntendRot = math.max( minTorsoRotLimit, math.min( torsoIntendRot, maxTorsoRotLimit)) -- abide torso rotation limit
--                            end

--                        elseif (wep1CurTargetAngle - torsoIntendRot) >= wep1YawRangeMax then
--                            -- weapon 1 can't hit target with new rotation - have weapon 2 also target weapon 1's target
--                            if allowRetarget and wep1Target then  -- if weapon 1 has a valid target have wep 2 also target that
--                                wep2:SetTargetEntity( wep1Target )
--                                torsoIntendRot = wep1CurTargetAngle
--                                torsoIntendRot = math.max( minTorsoRotLimit, math.min( torsoIntendRot, maxTorsoRotLimit)) -- abide torso rotation limit
--                            else  -- if no valid target then at least give wep 1 the room to fire. Rotate so target 1 is just in firing arc for wep 1
--                                torsoIntendRot = torsoIntendRot + (wep1CurTargetAngle - torsoIntendRot - wep1YawRangeMax)  -- max!
--                                torsoIntendRot = math.max( minTorsoRotLimit, math.min( torsoIntendRot, maxTorsoRotLimit)) -- abide torso rotation limit
--                            end

                        -- Now check weapon 2. If it can't hit the target perhaps rotating the torso a bit more will do it, so check if that's
                        -- possible. If not, retarget.

--                        elseif (wep2CurTargetAngle - torsoIntendRot) <= wep2YawRangeMin then
--                            -- wep 2 can't hit. Check if wep 2 can hit if torso rotates a bit more. If not, retarget or use best rotation possible
--                            local wep1YawRemaining = math.min( math.abs(torsoIntendRot + wep1YawRangeMin - wep1CurTargetAngle), math.abs(torsoIntendRot + wep1YawRangeMax - wep1CurTargetAngle) )
--                            local wep2YawNeeded = wep2CurTargetAngle - torsoIntendRot - wep2YawRangeMin
--                            if math.abs(wep2YawNeeded) < wep1YawRemaining then
--                                torsoIntendRot = torsoIntendRot + wep2YawNeeded  -- rotate a bit more for wep 2
--                                torsoIntendRot = math.max( minTorsoRotLimit, math.min( torsoIntendRot, maxTorsoRotLimit)) -- abide torso rotation limit
--                            elseif allowRetarget and wep1Target then  -- retarget wep 2, only if there is a target
--                                wep2:SetTargetEntity( wep1Target )
--                                torsoIntendRot = wep1CurTargetAngle
--                                torsoIntendRot = math.max( minTorsoRotLimit, math.min( torsoIntendRot, maxTorsoRotLimit)) -- abide torso rotation limit
--                            else  -- no valid target, at least let wep 1 fire. Rotate so target 1 is just in firing arc for wep 1
--                                torsoIntendRot = torsoIntendRot + (wep1CurTargetAngle - torsoIntendRot - wep1YawRangeMin)  -- min!
--                                torsoIntendRot = math.max( minTorsoRotLimit, math.min( torsoIntendRot, maxTorsoRotLimit)) -- abide torso rotation limit
--                            end

--                        elseif (wep2CurTargetAngle - torsoIntendRot) >= wep2YawRangeMax then
--                            -- wep 2 can't hit. Check if wep 2 can hit if torso rotates a bit more. If not, retarget or use best rotation possible
--                            local wep1YawRemaining = math.min( math.abs(torsoIntendRot + wep1YawRangeMin - wep1CurTargetAngle), math.abs(torsoIntendRot + wep1YawRangeMax - wep1CurTargetAngle) )
--                            local wep2YawNeeded = wep2CurTargetAngle - torsoIntendRot - wep2YawRangeMax
--                            if math.abs(wep2YawNeeded) < wep1YawRemaining then
--                                torsoIntendRot = torsoIntendRot + wep2YawNeeded  -- rotate a bit more for wep 2
--                                torsoIntendRot = math.max( minTorsoRotLimit, math.min( torsoIntendRot, maxTorsoRotLimit)) -- abide torso rotation limit
--                            elseif allowRetarget and wep1Target then  -- retarget wep 2, only if there is a target
--                                wep2:SetTargetEntity( wep1Target )
--                                torsoIntendRot = wep1CurTargetAngle
--                                torsoIntendRot = math.max( minTorsoRotLimit, math.min( torsoIntendRot, maxTorsoRotLimit)) -- abide torso rotation limit
--                            else  -- no valid target, at least let wep 1 fire. Rotate so target 1 is just in firing arc for wep 1
--                                torsoIntendRot = torsoIntendRot + (wep1CurTargetAngle - torsoIntendRot - wep1YawRangeMax)  -- max!
--                                torsoIntendRot = math.max( minTorsoRotLimit, math.min( torsoIntendRot, maxTorsoRotLimit)) -- abide torso rotation limit
--                            end
--                        end
                    end

                    torsoIntendRot = torsoRot + torsoIntendRot  -- don't forget current torso rotation!
                end

                -- Rotate torso with new found rotation!
                self.TorsoRotManip:SetSpeed( torsoRotSpeed ):SetGoal(torsoIntendRot)

                if doHeadRotation then
                    -- Head rotation is next. The head should "look" at target of wep 1, target of wep2, where it is going, or be in default rotation (in this order).
                    headTargetPos = wep1TargetPos or wep2TargetPos or nav:GetCurrentTargetPos() -- Get the location of interest

                    -- calculate the angle for the head rotation. The rotation of the torso is taken into account. Since the head shouldn't rotate
                    -- 360 degrees also limit the rotation.
                    headIntendRot = math.max( -headRotLimit, math.min( headRotLimit, GetTargetAngle( self, headTargetPos, torsoDir )))

                    -- rotate head
                    self.HeadRotManip:SetSpeed( headRotSpeed ):SetGoal(headIntendRot)
                end

                WaitSeconds(0.3) -- rinse and repeat after this
            end
        end,
    }
end

-- ================================================================================================================
-- CAPACITOR
-- ================================================================================================================

function AddCapacitorAbility( SuperClass )
    -- The capacitor ability boosts the unit for a short time. It doesn't work with shielded units because this
    -- ability uses the shield indicator on the unit for the capacity in the capacitor.
        
    return Class(SuperClass) {
    
        CapDoPlayFx = true,
        CapFxBones = nil,
        CapFxBeingUsedTemplate = NomadsEffectTemplate.CapacitorBeingUsed,
        CapFxChargingTemplate = NomadsEffectTemplate.CapacitorCharging,
        CapFxEmptyTemplate = NomadsEffectTemplate.CapacitorEmpty,
        CapFxFullTemplate = NomadsEffectTemplate.CapacitorFull,
        
        OnCreate = function(self)
            SuperClass.OnCreate(self)
            
            self:HasCapacitorAbility(true)
            self.CapActive = false
            self.CapChargeWhenFull = 100
            self.CapCurCharge = 0
            self:SetCapacitorCooldown(self:GetBlueprint().Abilities.Capacitor.Cooldown)
            self:SetCapacitorDuration(self:GetBlueprint().Abilities.Capacitor.Duration)
            self:SetCapacitorEnergyCost(self:GetBlueprint().Abilities.Capacitor.EnergyCost)
            self.CapFxBag = TrashBag()
        end,
        
        OnStopBeingBuilt = function(self,builder,layer)
            self.Sync.Abilities = self:GetBlueprint().Abilities
            SuperClass.OnStopBeingBuilt(self,builder,layer)
        end,
        
        OnKilled = function(self, instigator, type, overkillRatio)
            SuperClass.OnKilled(self, instigator, type, overkillRatio)
        end,
        
        OnCapStartBeingUsed = function(self, duration)
        end,
        
        OnCapStopBeingUsed = function(self)
        end,
        
        CapIsBeingUsed = function(self)
        end,
        
        HasCapacitorAbility = function(self, hasIt)
            self.Sync.HasCapacitorAbility = hasIt
        end,
        
        SetCapacitorEnergyCost = function(self, energyCost)
            self.Sync.CapacitorEnergyCost = energyCost
        end,
        
        SetCapacitorDuration = function(self, duration)
            self.CapDuration = duration
        end,
        
        SetCapacitorCooldown = function(self, cooldown)
            self.CapCooldown = cooldown
        end,
        
        CapUpdateBar = function(self)
            self:SetShieldRatio( self:CapGetCapacityFrac() )
        end,
        
        CapGetCapacityFrac = function(self)
            if self.CapCurCharge < 0 then self.CapCurCharge = 0 end
            if self.CapCurCharge == 0 or self.CapChargeWhenFull == 0 then
                return 0
            end
            return (self.CapCurCharge / self.CapChargeWhenFull)
        end,
        
        TryToActivateCapacitor = function(self)        
            if self.CapActive then
                WARN('Trying to use Capacitor while its already active!')
                return
            end
            
            # Initial energy drain here - we drain resources instantly when capacitor is activated
            local aiBrain = self:GetAIBrain()
            local have = aiBrain:GetEconomyStored('ENERGY')
            if not ( have > self.Sync.CapacitorEnergyCost ) then
                return
            end
            
            # Drain economy here
            aiBrain:TakeResource( 'ENERGY', self.Sync.CapacitorEnergyCost )
            
            self:ActivateCapacitor()
        end,
        
        ActivateCapacitor = function(self)

            while self:IsStunned() do  -- dont waste capacitor time being stunned
                WaitTicks(1)
            end

            self:CapPlayFx('BeingUsed')

            local bp = self:GetBlueprint().Abilities
            local buffs = bp.Capacitor.Buffs or {}
            local duration = bp.Duration

            -- apply buffs
            for k, buffName in buffs do
                Buff.ApplyBuff( self, buffName )
            end

            -- notify weapons
            for i = 1, self:GetWeaponCount() do
                local wep = self:GetWeapon(i)
                if wep.UseCapacitorBoost then
                    wep:OnCapStartBeingUsed( duration )
                end
            end

            self:UpdateConsumptionValues()
            self:OnCapStartBeingUsed( duration )
            self.CapActive = true
            if self.CapStateThreadHandle then KillThread( self.CapStateThreadHandle ) end
            self.CapStateThreadHandle = self:ForkThread( self.CapacitorMain )
            self.CooldownThread = self:ForkThread( self.CooldownMain )
        end,
        
        CapacitorMain = function(self)
            local i = self.CapDuration
            self.CapCurCharge = self.CapChargeWhenFull
            while self.CapCurCharge > 0 do
                self.CapCurCharge = (i / self.CapDuration) * self.CapChargeWhenFull
                self:CapUpdateBar()
                i = i - 0.1
                WaitTicks(1)
            end
            self.CapCurCharge = 0
            self:CapUpdateBar()
            
            self:DeactivateCapacitor()
        end,
        
        CooldownMain = function(self)
            self.Sync.CooldownTimer = self.CapCooldown
            
            while(self.Sync.CooldownTimer > 0) do
                WaitSeconds(1)
                self.Sync.CooldownTimer = self.Sync.CooldownTimer - 1
            end
        end,
        
        DeactivateCapacitor = function(self)
            
            local bp = self:GetBlueprint().Abilities
            local buffs = bp.Capacitor.Buffs or {}
            -- remove buffs
            for k, buffName in buffs do
                Buff.RemoveBuff( self, buffName )
            end

            -- notify weapons again
            for i = 1, self:GetWeaponCount() do
                local wep = self:GetWeapon(i)
                if wep.UseCapacitorBoost then
                    wep:OnCapStopBeingUsed()
                end
            end

            self:CapPlayFx('StopBeingUsed')
            self:UpdateConsumptionValues()
            self:OnCapStopBeingUsed()
            self.CapActive = false
            
            if self.CapStateThreadHandle then KillThread( self.CapStateThreadHandle ) end
        end,
        
        CapPlayFx = function(self, state)
            if self.CapFxBones and self.CapDoPlayFx then
                local templ = {}

                if state == 'Empty' then
                    templ = self.CapFxEmptyTemplate
                    self:StopUnitAmbientSound('CapacitorInUseLoop')
                    self:PlayUnitSound('CapacitorEmpty')
                    --AddVOUnitEvent(self, 'CapacitorEmpty')
                elseif state == 'Charging' then
                    templ = self.CapFxChargingTemplate
                    self:StopUnitAmbientSound('CapacitorInUseLoop')
                    self:PlayUnitSound('CapacitorStartCharging')
                elseif state == 'Full' then
                    templ = self.CapFxFullTemplate
                    self:StopUnitAmbientSound('CapacitorInUseLoop')
                    self:PlayUnitSound('CapacitorFull')
                    AddVOUnitEvent(self, 'CapacitorFull')
                elseif state == 'BeingUsed' then
                    templ = self.CapFxBeingUsedTemplate
                    self:PlayUnitSound('CapacitorStartBeingUsed')
                    self:PlayUnitAmbientSound('CapacitorInUseLoop')
                elseif state == 'StopBeingUsed' then
                    self:StopUnitAmbientSound('CapacitorInUseLoop')
                    self:PlayUnitSound('CapacitorStopBeingUsed')
                end

                self:CapDestroyFx()
                local ox, oy, oz
                local army, emit = self:GetArmy()
                for bk, bone in self.CapFxBones do
                    ox = self.CapFxBonesOffsets[bk][1] or 0
                    oy = self.CapFxBonesOffsets[bk][2] or 0
                    oz = self.CapFxBonesOffsets[bk][3] or 0
                    for k, v in templ do
                        emit = CreateAttachedEmitter(self, bone, army, v)
                        emit:OffsetEmitter(ox, oy, oz)
                        self.CapFxBag:Add(emit)
                    end
                end
            end
        end,

        CapDestroyFx = function(self)
            self.CapFxBag:Destroy()
        end,
        
        -- don't do shield things
        EnableShield = function(self)
            WARN('Shields disabled by capacitor ability...')
        end,

        DisableShield = function(self)
            WARN('Shields disabled by capacitor ability...')
        end,
    }
end

function AddCapacitorAbilityToWeapon( SuperClass )
    -- The capacitor ability code for weapons

    return Class(SuperClass) {

        UseCapacitorBoost = true,

        CapGetWepAffectingEnhancementBP = function(self)
            -- Overwrite on SCUs and ACUs to have support for weapon enhancements. There are requirements to the values in the returned table.
            -- All values in the enhancement should begin with "New". See code below to find all supported bp values.
            return {}
        end,

        GetDamageTable = function(self)
            -- if capacitor in use pass different data to projectile, to create DoT effect
            local damageTable = SuperClass.GetDamageTable(self)
            if self:CapIsBeingUsed() then
                local ebp = self:CapGetWepAffectingEnhancementBP()
                local wbp = self:GetBlueprint()
                damageTable.DamageAmount        = ebp.NewDamageDuringCapacitor or wbp.DamageDuringCapacitor or damageTable.DamageAmount
                damageTable.DamageRadius        = ebp.NewDamageRadiusDuringCapacitor or wbp.DamageRadiusDuringCapacitor or damageTable.DamageRadius
                damageTable.DamageToShields     = ebp.NewDamageToShieldsDuringCapacitor or wbp.DamageToShieldsDuringCapacitor or damageTable.DamageToShields
                damageTable.DoTTime             = ebp.NewDoTTimeDuringCapacitor or wbp.DoTTimeDuringCapacitor or damageTable.DoTTime
                damageTable.DoTPulses           = ebp.NewDoTPulsesDuringCapacitor or wbp.DoTPulsesDuringCapacitor or damageTable.DoTPulses
                damageTable.InitialDamageAmount = ebp.NewInitialDamageDuringCapacitor or wbp.InitialDamageDuringCapacitor or damageTable.InitialDamageAmount
            end
            return damageTable
        end,

        OnCapStartBeingUsed = function(self, duration)
            -- Changes several aspects of the weapon. Please note that ROF is handled through a unit buff. It is actually the only weapon
            -- aspect that can be handled this way. Using buffs is needed for compatibility with other features such as bombard.
            --LOG('*DEBUG: wep OnCapStartBeingUsed( duration = '..repr(duration)..')')

            local ebp = self:CapGetWepAffectingEnhancementBP()
            local wbp = self:GetBlueprint()
            local newProjwbp = ebp.NewProjectileIdDuringCapacitor or wbp.ProjectileIdDuringCapacitor or wbp.ProjectileId

            self:ChangeProjectileBlueprint(newProjwbp)
        end,

        OnCapStopBeingUsed = function(self)
            --LOG('*DEBUG: wep OnCapStopBeingUsed()')

            local wbp = self:GetBlueprint()
            local newProjwbp = wbp.ProjectileId

            self:ChangeProjectileBlueprint(newProjwbp)
        end,

        CapIsBeingUsed = function(self)
            return self.unit:CapIsBeingUsed()
        end,
    }
end

-- ================================================================================================================
-- ANCHOR
-- ================================================================================================================

function AddAnchorAbilty(SuperClass)
    return Class(SuperClass) {

        EnableAnchor = function(self)
            local bp = self:GetBlueprint().Abilities.Anchor
            local BuffName = bp.Buff or 'AnchorModeImmobilize'
            Buff.ApplyBuff(self, BuffName)
        end,

        DisableAnchor = function(self)
            local bp = self:GetBlueprint().Abilities.Anchor
            local BuffName = bp.Buff or 'AnchorModeImmobilize'
            Buff.RemoveBuff(self, BuffName)
        end,
    }
end