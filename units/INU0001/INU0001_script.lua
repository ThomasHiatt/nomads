-- Nomads ACU

local Entity = import('/lua/sim/Entity.lua').Entity
local Buff = import('/lua/sim/Buff.lua')
local EffectTemplate = import('/lua/EffectTemplates.lua')
local Utilities = import('/lua/utilities.lua')
local NomadsEffectUtil = import('/lua/nomadseffectutilities.lua')

local NUtils = import('/lua/nomadsutils.lua')
local AddRapidRepair = NUtils.AddRapidRepair
local AddRapidRepairToWeapon = NUtils.AddRapidRepairToWeapon
local AddCapacitorAbility = NUtils.AddCapacitorAbility
local AddCapacitorAbilityToWeapon = NUtils.AddCapacitorAbilityToWeapon

local NWeapons = import('/lua/nomadsweapons.lua')
local APCannon1 = NWeapons.APCannon1
local APCannon1_Overcharge = NWeapons.APCannon1_Overcharge
local DeathNuke = NWeapons.DeathNuke

APCannon1 = AddCapacitorAbilityToWeapon(APCannon1)
APCannon1_Overcharge = AddCapacitorAbilityToWeapon(APCannon1_Overcharge)

ACUUnit = AddCapacitorAbility(AddRapidRepair(import('/lua/defaultunits.lua').ACUUnit))

INU0001 = Class(ACUUnit) {

    Weapons = {
        MainGun = Class(AddRapidRepairToWeapon(APCannon1)) {
            CreateProjectileAtMuzzle = function(self, muzzle)
                if self.unit.DoubleBarrels then
                    APCannon1.CreateProjectileAtMuzzle(self, 'right_arm_upgrade_muzzle')
                end
                return APCannon1.CreateProjectileAtMuzzle(self, muzzle)
            end,

            CapGetWepAffectingEnhancementBP = function(self)
                if self.unit:HasEnhancement('DoubleGuns') then
                    return self.unit:GetBlueprint().Enhancements['DoubleGuns']
                elseif self.unit:HasEnhancement('GunUpgrade') then
                    return self.unit:GetBlueprint().Enhancements['GunUpgrade']
                else
                    return {}
                end
            end,
        },
        AutoOverCharge = Class(AddRapidRepairToWeapon(APCannon1_Overcharge)) {
            PlayFxMuzzleSequence = function(self, muzzle)
                APCannon1_Overcharge.PlayFxMuzzleSequence(self, muzzle)

                -- create extra effect
                local bone = self:GetBlueprint().RackBones[1]['RackBone']
                for k, v in EffectTemplate.TCommanderOverchargeFlash01 do
                    CreateAttachedEmitter(self.unit, bone, self.unit:GetArmy(), v):ScaleEmitter(self.FxMuzzleFlashScale)
                end
            end,
        },
        OverCharge = Class(AddRapidRepairToWeapon(APCannon1_Overcharge)) {
            PlayFxMuzzleSequence = function(self, muzzle)
                APCannon1_Overcharge.PlayFxMuzzleSequence(self, muzzle)

                -- create extra effect
                local bone = self:GetBlueprint().RackBones[1]['RackBone']
                for k, v in EffectTemplate.TCommanderOverchargeFlash01 do
                    CreateAttachedEmitter(self.unit, bone, self.unit:GetArmy(), v):ScaleEmitter(self.FxMuzzleFlashScale)
                end
            end,
        },
        DeathWeapon = Class(DeathNuke) {},
    },

    __init = function(self)
        ACUUnit.__init(self, 'MainGun')
    end,
    
    -- =====================================================================================================================
    -- CREATION AND FIRST SECONDS OF GAMEPLAY

    CapFxBones = { 'torso_thingy_left', 'torso_thingy_right', },
    
    OnCreate = function(self)
        ACUUnit.OnCreate(self)

        local bp = self:GetBlueprint()

        -- vars
        self.DoubleBarrels = false
        self.DoubleBarrelOvercharge = false
        self.EnhancementBoneEffectsBag = {}
        self.BuildBones = bp.General.BuildBones.BuildEffectBones
        self.HeadRotationEnabled = false -- disable head rotation to prevent initial wrong rotation
        self.AllowHeadRotation = false
        self.UseRunWalkAnim = false

        -- model
        self:HideBone('right_arm_upgrade_muzzle', true)
        self:HideBone('left_arm_upgrade_muzzle', true)
        self:HideBone('upgrade_back', true)

        self.HeadRotManip = CreateRotator(self, 'head', 'y', nil):SetCurrentAngle(0)
        self.Trash:Add(self.HeadRotManip)

        -- properties
        self:SetCapturable(false)
        self:SetupBuildBones()

        -- enhancements
        self:RemoveToggleCap('RULEUTC_SpecialToggle')
        self:AddBuildRestriction( categories.NOMADS * (categories.BUILTBYTIER2COMMANDER + categories.BUILTBYTIER3COMMANDER) )
        self:SetRapidRepairParams( 'NomadsACURapidRepair', bp.Enhancements.RapidRepair.RepairDelay, bp.Enhancements.RapidRepair.InterruptRapidRepairByWeaponFired)

        self.Sync.Abilities = self:GetBlueprint().Abilities
        self:HasCapacitorAbility(false)
    end,

    OnStopBeingBuilt = function(self, builder, layer)
        ACUUnit.OnStopBeingBuilt(self, builder, layer)
        self:SetWeaponEnabledByLabel('MainGun', true)
        self:ForkThread(self.GiveInitialResources)
        self:ForkThread(self.HeadRotationThread)

        self:ForkThread(self.DoMeteorAnim)
    end,

    -- =====================================================================================================================
    -- UNIT DEATH

    OnKilled = function(self, instigator, type, overkillRatio)
        self:SetOrbitalBombardEnabled(false)
        self:SetIntelProbeEnabled(true, false)
        self:SetIntelProbeEnabled(false, false)
        ACUUnit.OnKilled(self, instigator, type, overkillRatio)
    end,

    DeathThread = function( self, overkillRatio, instigator)
        -- since we're spawning a black hole the ACU disappears right away
        self:Destroy()
    end,

    OnStartBuild = function(self, unitBeingBuilt, order)

       local bp = self:GetBlueprint()

        if order ~= 'Upgrade' or bp.Display.ShowBuildEffectsDuringUpgrade then

            -- If we are assisting an upgrading unit, or repairing a unit, play seperate effects
            local UpgradesFrom = unitBeingBuilt:GetBlueprint().General.UpgradesFrom
            if (order == 'Repair' and not unitBeingBuilt:IsBeingBuilt()) or (UpgradesFrom and UpgradesFrom ~= 'none' and self:IsUnitState('Guarding')) or (order == 'Repair'  and self:IsUnitState('Guarding') and not unitBeingBuilt:IsBeingBuilt()) then
                self:ForkThread( NomadsEffectUtil.CreateRepairBuildBeams, unitBeingBuilt, self.BuildBones, self.BuildEffectsBag )
            else
                self:ForkThread( NomadsEffectUtil.CreateNomadsBuildSliceBeams, unitBeingBuilt, self.BuildBones, self.BuildEffectsBag )   
            end
        end

        self:DoOnStartBuildCallbacks(unitBeingBuilt)
        self:SetActiveConsumptionActive()
        self:PlayUnitSound('Construct')
        self:PlayUnitAmbientSound('ConstructLoop')
        if bp.General.UpgradesTo and unitBeingBuilt:GetUnitId() == bp.General.UpgradesTo and order == 'Upgrade' then
            unitBeingBuilt.DisallowCollisions = true
        end
        
        if unitBeingBuilt:GetBlueprint().Physics.FlattenSkirt and not unitBeingBuilt:HasTarmac() then
            if self.TarmacBag and self:HasTarmac() then
                unitBeingBuilt:CreateTarmac(true, true, true, self.TarmacBag.Orientation, self.TarmacBag.CurrentBP )
            else
                unitBeingBuilt:CreateTarmac(true, true, true, false, false)
            end
        end           

        self.UnitBeingBuilt = unitBeingBuilt
        self.UnitBuildOrder = order
        self.BuildingUnit = true
    end,
    
    -- use our own reclaim animation
    CreateReclaimEffects = function( self, target )
        NomadsEffectUtil.PlayNomadsReclaimEffects( self, target, self:GetBlueprint().General.BuildBones.BuildEffectBones or {0,}, self.ReclaimEffectsBag )
    end,
    
    -- =====================================================================================================================
    -- GENERIC

    OnMotionHorzEventChange = function( self, new, old )
        if old == 'Stopped' and self.UseRunWalkAnim then
            local bp = self:GetBlueprint()
            if bp.Display.AnimationRun then
                if not self.Animator then
                    self.Animator = CreateAnimator(self, true)
                end
                self.Animator:PlayAnim(bp.Display.AnimationRun, true)
                self.Animator:SetRate(bp.Display.AnimationRunRate or 1)
            else
                ACUUnit.OnMotionHorzEventChange(self, new, old)
            end
        else
            ACUUnit.OnMotionHorzEventChange(self, new, old)
        end
    end,


    -- =====================================================================================================================
    -- EFFECTS AND ANIMATIONS

    -------- INITIAL ANIM --------

    DoMeteorAnim = function(self)  -- part of initial dropship animation

        self.PlayCommanderWarpInEffectFlag = false
        self:HideBone(0, true)
        self:SetWeaponEnabledByLabel('MainGun', false)
        self:CapDestroyFx()
        self.CapDoPlayFx = false

        local meteor = self:CreateProjectile('/effects/Entities/NomadsACUDropMeteor/NomadsACUDropMeteor_proj.bp')
        self.Trash:Add(meteor)
        meteor:Start(self:GetPosition(), 3)

        WaitTicks(35) -- time before meteor opens

        self:ShowBone(0, true)
        self:HideBone('right_arm_upgrade_muzzle', true)
        self:HideBone('left_arm_upgrade_muzzle', true)
        self:HideBone('upgrade_back', true)

        local totalBones = self:GetBoneCount() - 1
        local army = self:GetArmy()
        for k, v in EffectTemplate.UnitTeleportSteam01 do
            for bone = 1, totalBones do
                CreateAttachedEmitter(self,bone,army, v)
            end
        end

        self.CapDoPlayFx = true

        WaitTicks(5)

        -- TODO: play some kind of animation here?
        self.AllowHeadRotation = true
        self.PlayCommanderWarpInEffectFlag = nil

        WaitTicks(12)  -- waiting till tick 50 to enable ACU. Same as other ACU's.

        self:SetWeaponEnabledByLabel('MainGun', true)
        self:SetUnSelectable(false)
        self:SetBusy(false)
        self:SetBlockCommandQueue(false)
    end,

    PlayCommanderWarpInEffect = function(self)  -- part of initial dropship animation
        self:SetUnSelectable(true)
        self:SetBusy(true)
        self:SetBlockCommandQueue(true)
        self.PlayCommanderWarpInEffectFlag = true
    end,

    HeadRotationThread = function(self)
        -- keeps the head pointed at the current target (position)

        local nav = self:GetNavigator()
        local maxRot = self:GetBlueprint().Display.MovementEffects.HeadRotationMax or 10
        local wep = self:GetWeaponByLabel('MainGun')
        local GoalAngle = 0
        local target, torsoDir, torsoX, torsoY, torsoZ, MyPos

        while not self:IsDead() do

            -- don't rotate if we're not allowed to
            while not self.HeadRotationEnabled do
                WaitSeconds(0.2)
            end

            -- get a location of interest. This is the unit we're currently firing on or, alternatively, the position we're moving to
            target = wep:GetCurrentTarget()
            if target and target.GetPosition then
                target = target:GetPosition()
            else
                target = wep:GetCurrentTargetPos() or nav:GetCurrentTargetPos()
            end

            -- calculate the angle for the head rotation. The rotation of the torso is taken into account
            MyPos = self:GetPosition()
            target.y = 0
            target.x = target.x - MyPos.x
            target.z = target.z - MyPos.z
            target = Utilities.NormalizeVector(target)
            torsoX, torsoY, torsoZ = self:GetBoneDirection('torso')
            torsoDir = Utilities.NormalizeVector( Vector( torsoX, 0, torsoZ) )
            GoalAngle = ( math.atan2( target.x, target.z ) - math.atan2( torsoDir.x, torsoDir.z ) ) * 180 / math.pi

            -- rotation limits, sometimes the angle is more than 180 degrees which causes a bad rotation.
            if GoalAngle > 180 then
                GoalAngle = GoalAngle - 360
            elseif GoalAngle < -180 then
                GoalAngle = GoalAngle + 360
            end
            GoalAngle = math.max( -maxRot, math.min( GoalAngle, maxRot ) )

            self.HeadRotManip:SetSpeed(60):SetGoal(GoalAngle)

            WaitSeconds(0.2)
        end
    end,

    AddEnhancementEmitterToBone = function(self, add, bone)

        -- destroy effect, if any
        if self.EnhancementBoneEffectsBag[ bone ] then
            self.EnhancementBoneEffectsBag[ bone ]:Destroy()
        end

        -- add the effect if desired
        if add then
            local emitBp = self:GetBlueprint().Display.EnhancementBoneEmitter
            local emit = CreateAttachedEmitter( self, bone, self:GetArmy(), emitBp )
            self.EnhancementBoneEffectsBag[ bone ] = emit
            self.Trash:Add( self.EnhancementBoneEffectsBag[ bone ] )
        end
    end,

    UpdateMovementEffectsOnMotionEventChange = function( self, new, old )
        self.HeadRotationEnabled = self.AllowHeadRotation
        ACUUnit.UpdateMovementEffectsOnMotionEventChange( self, new, old )
    end,

    -- =====================================================================================================================
    -- ORBITAL ENHANCEMENTS

    SetOrbitalBombardEnabled = function(self, enable)
        local brain = self:GetAIBrain()
        brain:EnableSpecialAbility( 'NomadsAreaBombardment', (enable == true) )
    end,

    SetIntelProbeEnabled = function(self, adv, enable)
        local brain = self:GetAIBrain()
        if enable then
            local EnAbil, DisAbil = 'NomadsIntelProbe', 'NomadsIntelProbeAdvanced'
            if adv then
                EnAbil = 'NomadsIntelProbeAdvanced'
                DisAbil = 'NomadsIntelProbe'
            end
            brain:EnableSpecialAbility( DisAbil, false )
            brain:EnableSpecialAbility( EnAbil, true )
        else
            brain:EnableSpecialAbility( 'NomadsIntelProbeAdvanced', false )
            brain:EnableSpecialAbility( 'NomadsIntelProbe', false )
        end
    end,

    -- =====================================================================================================================
    -- ENHANCEMENTS

    CreateEnhancement = function(self, enh)
        
        ACUUnit.CreateEnhancement(self, enh)

        local bp = self:GetBlueprint().Enhancements[enh]
        if not bp then return end

        -- ---------------------------------------------------------------------------------------
        -- INTEL PROBE
        -- ---------------------------------------------------------------------------------------

        if enh == 'IntelProbe' then
            self:AddEnhancementEmitterToBone( true, 'right_shoulder_pod' )
            self:SetIntelProbeEnabled( false, true )

        elseif enh == 'IntelProbeRemove' then
            self:AddEnhancementEmitterToBone( false, 'right_shoulder_pod' )
            self:SetIntelProbeEnabled( false, false )

        -- ---------------------------------------------------------------------------------------
        -- ADVANCED INTEL PROBE
        -- ---------------------------------------------------------------------------------------

        elseif enh == 'IntelProbeAdv' then
--            self:AddEnhancementEmitterToBone( true, 'right_shoulder_pod' )
            self:SetIntelProbeEnabled( true, true )

        elseif enh == 'IntelProbeAdvRemove' then
            self:AddEnhancementEmitterToBone( false, 'right_shoulder_pod' )
            self:SetIntelProbeEnabled( true, false )

        -- ---------------------------------------------------------------------------------------
        -- MAIN WEAPON UPGRADE
        -- ---------------------------------------------------------------------------------------

        elseif enh == 'GunUpgrade' then

            local wep = self:GetWeaponByLabel('MainGun')
            local wbp = wep:GetBlueprint()

            if bp.RateOfFireMulti then
                if not Buffs['NOMADSACUGunUpgrade'] then
                    BuffBlueprint {
                        Name = 'NOMADSACUGunUpgrade',
                        DisplayName = 'NOMADSACUGunUpgrade',
                        BuffType = 'ACUGUNUPGRADE',
                        Stacks = 'ADD',
                        Duration = -1,
                        Affects = {
                            RateOfFireSpecifiedWeapons = {
                                Mult = 1 / (bp.RateOfFireMulti or 1), -- here a value of 0.5 is actually doubling ROF
                            },
                        },
                    }
                end
                if Buff.HasBuff( self, 'NOMADSACUGunUpgrade' ) then
                    Buff.RemoveBuff( self, 'NOMADSACUGunUpgrade' )
                end
                Buff.ApplyBuff(self, 'NOMADSACUGunUpgrade')
            end

            -- adjust main gun
            wep:AddDamageMod( (bp.NewDamage or wbp.Damage) - wbp.Damage )
            wep:ChangeMaxRadius(bp.NewMaxRadius or wbp.MaxRadius)

            -- adjust overcharge gun
            local oc = self:GetWeaponByLabel('OverCharge')
            oc:ChangeMaxRadius( bp.NewMaxRadius or wbp.MaxRadius )
            local oca = self:GetWeaponByLabel('AutoOverCharge')
            oca:ChangeMaxRadius( bp.NewMaxRadius or wbp.MaxRadius )

        elseif enh =='GunUpgradeRemove' then
            Buff.RemoveBuff( self, 'NOMADSACUGunUpgrade' )

            -- adjust main gun
            local wep = self:GetWeaponByLabel('MainGun')
            local wbp = wep:GetBlueprint()
            wep:AddDamageMod( -((bp.NewDamage or wbp.Damage) - wbp.Damage) )
            wep:ChangeMaxRadius(wbp.MaxRadius)

            -- adjust overcharge gun
            local oc = self:GetWeaponByLabel('OverCharge')
            oc:ChangeMaxRadius( wbp.MaxRadius )
            local oca = self:GetWeaponByLabel('AutoOverCharge')
            oca:ChangeMaxRadius( bp.NewMaxRadius or wbp.MaxRadius )

        -- ---------------------------------------------------------------------------------------
        -- MAIN WEAPON UPGRADE 2
        -- ---------------------------------------------------------------------------------------

        elseif enh =='DoubleGuns' then
            -- this one should not change weapon damage, range, etc. The weapon script can't cope with that.
            self.DoubleBarrels = true
            self.DoubleBarrelOvercharge = bp.OverchargeIncluded

        elseif enh =='DoubleGunsRemove' then
            self.DoubleBarrels = false
            self.DoubleBarrelOvercharge = false

            Buff.RemoveBuff( self, 'NOMADSACUGunUpgrade' )

            -- adjust main gun
            local ubp = self:GetBlueprint()
            local wep = self:GetWeaponByLabel('MainGun')
            local wbp = wep:GetBlueprint()
            wep:AddDamageMod( -((ubp.Enhancements['GunUpgrade'].NewDamage or wbp.Damage) - wbp.Damage) )
            wep:ChangeMaxRadius(wbp.MaxRadius)

            -- adjust overcharge gun
            local oc = self:GetWeaponByLabel('OverCharge')
            oc:ChangeMaxRadius( wbp.MaxRadius )
            local oca = self:GetWeaponByLabel('AutoOverCharge')
            oca:ChangeMaxRadius( bp.NewMaxRadius or wbp.MaxRadius )

        -- ---------------------------------------------------------------------------------------
        -- LOCOMOTOR UPGRADE
        -- ---------------------------------------------------------------------------------------

        elseif enh == 'MovementSpeedIncrease' then
            self:SetSpeedMult( bp.SpeedMulti or 1.1 )
            self.UseRunWalkAnim = true

        elseif enh == 'MovementSpeedIncreaseRemove' then
            self:SetSpeedMult( 1 )
            self.UseRunWalkAnim = false

        -- ---------------------------------------------------------------------------------------
        -- CAPACITOR UPGRADE
        -- ---------------------------------------------------------------------------------------

        elseif enh == 'Capacitor' then
            self:HasCapacitorAbility(true)

        elseif enh == 'CapacitorRemove' then
            self:HasCapacitorAbility(false)

        -- ---------------------------------------------------------------------------------------
        -- RESOURCE ALLOCATION
        -- ---------------------------------------------------------------------------------------

        elseif enh =='ResourceAllocation' then

            local bpEcon = self:GetBlueprint().Economy
            self:SetProductionPerSecondEnergy(bp.ProductionPerSecondEnergy + bpEcon.ProductionPerSecondEnergy or 0)
            self:SetProductionPerSecondMass(bp.ProductionPerSecondMass + bpEcon.ProductionPerSecondMass or 0)

        elseif enh == 'ResourceAllocationRemove' then

            local bpEcon = self:GetBlueprint().Economy
            self:SetProductionPerSecondEnergy(bpEcon.ProductionPerSecondEnergy or 0)
            self:SetProductionPerSecondMass(bpEcon.ProductionPerSecondMass or 0)

        -- ---------------------------------------------------------------------------------------
        -- RAPID REPAIR
        -- ---------------------------------------------------------------------------------------

        elseif enh == 'RapidRepair' then

            if not Buffs['NomadsACURapidRepair'] then
                BuffBlueprint {
                    Name = 'NomadsACURapidRepair',
                    DisplayName = 'NomadsACURapidRepair',
                    BuffType = 'NOMADSACURAPIDREPAIRREGEN',
                    Stacks = 'ALWAYS',
                    Duration = -1,
                    Affects = {
                        Regen = {
                            Add = bp.RepairRate or 15,
                            Mult = 1.0,
                        },
                    },
                }
            end
            if not Buffs['NomadsACURapidRepairPermanentHPboost'] and bp.AddHealth > 0 then
                BuffBlueprint {
                    Name = 'NomadsACURapidRepairPermanentHPboost',
                    DisplayName = 'NomadsACURapidRepairPermanentHPboost',
                    BuffType = 'NOMADSACURAPIDREPAIRREGENPERMHPBOOST',
                    Stacks = 'ALWAYS',
                    Duration = -1,
                    Affects = {
                        MaxHealth = {
                           Add = bp.AddHealth or 0,
                           Mult = 1.0,
                        },
                    },
                }
            end
            if bp.AddHealth > 0 then
                Buff.ApplyBuff(self, 'NomadsACURapidRepairPermanentHPboost')
            end
            self:EnableRapidRepair(true)

        elseif enh == 'RapidRepairRemove' then

            -- keep in sync with same code in PowerArmorRemove
            self:EnableRapidRepair(false)
            if Buff.HasBuff( self, 'NomadsACURapidRepairPermanentHPboost' ) then
                Buff.RemoveBuff( self, 'NomadsACURapidRepair' )
                Buff.RemoveBuff( self, 'NomadsACURapidRepairPermanentHPboost' )
            end

        -- ---------------------------------------------------------------------------------------
        -- POWER ARMOR
        -- ---------------------------------------------------------------------------------------

        elseif enh =='PowerArmor' then

            if not Buffs['NomadsACUPowerArmor'] then
               BuffBlueprint {
                    Name = 'NomadsACUPowerArmor',
                    DisplayName = 'NomadsACUPowerArmor',
                    BuffType = 'NACUUPGRADEHP',
                    Stacks = 'ALWAYS',
                    Duration = -1,
                    Affects = {
                        MaxHealth = {
                            Add = bp.AddHealth,
                            Mult = 1.0,
                        },
                        Regen = {
                            Add = bp.AddRegenRate,
                            Mult = 1.0,
                        },
                    },
                }
            end
            if Buff.HasBuff( self, 'NomadsACUPowerArmor' ) then
                Buff.RemoveBuff( self, 'NomadsACUPowerArmor' )
            end
            Buff.ApplyBuff(self, 'NomadsACUPowerArmor')

            if bp.Mesh then
                self:SetMesh( bp.Mesh, true)
            end

        elseif enh == 'PowerArmorRemove' then

            local ubp = self:GetBlueprint()
            if bp.Mesh then
                self:SetMesh( ubp.Display.MeshBlueprint, true)
            end
            if Buff.HasBuff( self, 'NomadsACUPowerArmor' ) then
                Buff.RemoveBuff( self, 'NomadsACUPowerArmor' )
            end

            -- keep in sync with same code above
            self:EnableRapidRepair(false)
            if Buff.HasBuff( self, 'NomadsACURapidRepairPermanentHPboost' ) then
                Buff.RemoveBuff( self, 'NomadsACURapidRepair' )
                Buff.RemoveBuff( self, 'NomadsACURapidRepairPermanentHPboost' )
            end

        -- ---------------------------------------------------------------------------------------
        -- TECH 2 SUITE
        -- ---------------------------------------------------------------------------------------

        elseif enh =='AdvancedEngineering' then

            -- new build FX bone available
            table.insert( self.BuildBones, 'left_arm_upgrade_muzzle' )

            -- make new structures available
            local cat = ParseEntityCategory(bp.BuildableCategoryAdds)
            self:RemoveBuildRestriction(cat)

            -- add buff
            if not Buffs['NOMADSACUT2BuildRate'] then
                BuffBlueprint {
                    Name = 'NOMADSACUT2BuildRate',
                    DisplayName = 'NOMADSACUT2BuildRate',
                    BuffType = 'ACUBUILDRATE',
                    Stacks = 'REPLACE',
                    Duration = -1,
                    Affects = {
                        BuildRate = {
                            Add =  bp.NewBuildRate - self:GetBlueprint().Economy.BuildRate,
                            Mult = 1,
                        },
                        MaxHealth = {
                            Add = bp.NewHealth,
                            Mult = 1.0,
                        },
                        Regen = {
                            Add = bp.NewRegenRate,
                            Mult = 1.0,
                        },
                    },
                }
            end
      
            Buff.ApplyBuff(self, 'NOMADSACUT2BuildRate')
            self:updateBuildRestrictions()
        elseif enh =='AdvancedEngineeringRemove' then

            -- remove extra build bone
            table.removeByValue( self.BuildBones, 'left_arm_upgrade_muzzle' )

            -- buffs
            if Buff.HasBuff( self, 'NOMADSACUT2BuildRate' ) then
                Buff.RemoveBuff( self, 'NOMADSACUT2BuildRate' )
            end

            -- restore build restrictions
            self:RestoreBuildRestrictions()
      
            self:AddBuildRestriction( categories.NOMADS * (categories.BUILTBYTIER2COMMANDER + categories.BUILTBYTIER3COMMANDER) )
            self:updateBuildRestrictions()

        -- ---------------------------------------------------------------------------------------
        -- TECH 3 SUITE
        -- ---------------------------------------------------------------------------------------

        elseif enh =='T3Engineering' then

            -- make new structures available
            local cat = ParseEntityCategory(bp.BuildableCategoryAdds)
            self:RemoveBuildRestriction(cat)

            -- add buff
            if not Buffs['NOMADSACUT3BuildRate'] then
                BuffBlueprint {
                    Name = 'NOMADSACUT3BuildRate',
                    DisplayName = 'NOMADSCUT3BuildRate',
                    BuffType = 'ACUBUILDRATE',
                    Stacks = 'REPLACE',
                    Duration = -1,
                    Affects = {
                        BuildRate = {
                            Add =  bp.NewBuildRate - self:GetBlueprint().Economy.BuildRate,
                            Mult = 1,
                        },
                        MaxHealth = {
                            Add = bp.NewHealth,
                            Mult = 1.0,
                        },
                        Regen = {
                            Add = bp.NewRegenRate,
                            Mult = 1.0,
                        },
                    },
                }
            end
            Buff.ApplyBuff(self, 'NOMADSACUT3BuildRate')
            self:updateBuildRestrictions()

        elseif enh =='T3EngineeringRemove' then

            -- remove buff
            if Buff.HasBuff( self, 'NOMADSACUT3BuildRate' ) then
                Buff.RemoveBuff( self, 'NOMADSACUT3BuildRate' )
            end

            -- reset build restrictions
            self:RestoreBuildRestrictions()
            self:AddBuildRestriction( categories.NOMADS * ( categories.BUILTBYTIER2COMMANDER + categories.BUILTBYTIER3COMMANDER) )
            self:updateBuildRestrictions()

        -- ---------------------------------------------------------------------------------------
        -- ORBITAL BOMBARDMENT
        -- ---------------------------------------------------------------------------------------

        elseif enh == 'OrbitalBombardment' then
            self:SetOrbitalBombardEnabled(true)
            self:AddEnhancementEmitterToBone( true, 'left_shoulder_pod' )

        elseif enh == 'OrbitalBombardmentRemove' then
            self:SetOrbitalBombardEnabled(false)
            self:AddEnhancementEmitterToBone( false, 'left_shoulder_pod' )

        else
            WARN('Enhancement '..repr(enh)..' has no script support.')
	end
    end,
}

TypeClass = INU0001
