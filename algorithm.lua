-- ===========================================================================
-- `algorithm.lua` — Yliluoma's Ordered Dithering (Algorithm 1 + Enhancements)
-- ===========================================================================
-- 
-- A Lua port of Joel "Bisqwit" Yliluoma's arbitrary-palette positional dithering.
-- 
-- Features:
-- 
-- · Perceptually-weighted colour comparison (CCIR 601 luma)
-- · Psychovisual penalty to avoid harsh colour juxtapositions
-- · Analytical ratio solver (O(1) per pair instead of brute-force 64)
-- · Optional tri-tone 2×2 dithering for smoother gradients
-- 
-- Complexity: O(P²) for 2-colour, O(P³) with tri-tone (P = palette size)
-- Recommended for: retro graphics, animation-safe dithering, pre-rendered assets
-- ===============================================================================

-- Clamp a value to the range [min, max]
-- 
-- `value` (number): The number to constrain
-- `min` (number): Lower bound
-- `max` (number): Upper bound
-- returns (number): Clamped value
local function clamp(value, min, max)
    return value < min and min or value > max and max or value
end

-- Module table: exports public functions
local algorithm = {}

-- ========================
-- PERCEPTUAL COLOR METRICS
-- ========================

-- Compute perceptually-weighted distance between two RGB colours.
-- Uses CCIR 601 luma weights (0.299R + 0.587G + 0.114B) to match human vision,
-- where brightness differences are ~2 times more noticeable than chroma shifts.
-- 
-- Formula: error = 0.75 × (weighted chroma MSE) + 1.0 × (luma difference)²
-- 
-- `r1` (number), `g1` (number), `b1` (number): First colour
-- `r2` (number), `g2` (number), `b2` (number): Second colour
-- returns (number): Scalar error value (lower = more similar)
function algorithm.colourPerceptualDistance(r1, g1, b1, r2, g2, b2)
    -- Normalise RGB differences to [−1, 1] range for consistent weighting
    local dr, dg, db = (r1 - r2) / 255, (g1 - g2) / 255, (b1 - b2) / 255
    -- Compute luma difference using CCIR 601 coefficients
    -- Denominator: 255 × 1000 to keep values in [−1, 1] after integer math
    local lumaDifference = ((r1 - r2) * 299 + (g1 - g2) * 587 + (b1 - b2) * 114) / 255000
    -- Combine weighted chroma MSE (75% weight) + pure luma error (100% weight)
    return (dr * dr * 0.299 + dg * dg * 0.587 + db * db * 0.114) * 0.75 + lumaDifference * lumaDifference
end

-- Evaluate the total error of a proposed colour mix.
-- 
-- Combines two terms:
--   1. How well the mixed result matches the target colour
--   2. Psychovisual penalty for mixing visually distant colours
-- 
-- The penalty is scaled by (|ratio−0.5| + 0.5):
--   · ratio = 0.5 → factor = 0.5
--     (max penalty: 50/50 checkerboards are most visible)
--   · ratio = 0.0 or 1.0 → factor = 1.0
--     (min penalty: one colour dominates)
-- 
-- `tr` (number), `tg` (number), `tb` (number): Target colour (desired output)
-- `mr` (number), `mg` (number), `mb` (number): Mixed result (what c1+c2 at this ratio actually produces)
-- `c1r` (number), `c1g` (number), `c1b` (number): First component palette colour
-- `c2r` (number), `c2g` (number), `c2b` (number): Second component palette colour
-- `ratio` (number): Mixing proportion
--                   [0.0, 1.0] (0 = all c1, 1 = all c2)
-- returns (number): Total penalty score (lower = better plan)
function algorithm.evaluateMixingError(tr, tg, tb, mr, mg, mb, c1r, c1g, c1b, c2r, c2g, c2b, ratio)
    return (
        algorithm.colourPerceptualDistance(tr, tg, tb, mr, mg, mb) +
        algorithm.colourPerceptualDistance(c1r, c1g, c1b, c2r, c2g, c2b) *
        0.1 * (math.abs(ratio-0.5) + 0.5)
    )
end

-- =======================================================================
-- CORE PLANNER: Find optimal palette colours + mixing ratio for one pixel
-- =======================================================================

-- Determine the best way to approximate a target colour using the palette.
-- 
-- Searches two strategies:
--   A) Two-colour mixing:
--      find pair (c1,c2) + ratio that minimises error
--   B) Tri-tone mixing:
--      find triple (c1,c2,c3) for a fixed 2×2 pattern (50%/25%/25%)
-- 
-- Uses an analytical solver for the mixing ratio instead of brute-forcing 64
-- values:
-- 
--   ratio = weighted_average( 64 × (target − c1) / (c2 − c1) ) per channel
-- 
-- Weights use CCIR 601 luma coefficients to prioritise perceptually important
-- channels.
-- 
-- `bytesArray` (table[number, number, number]):
--     Palette as array of {r,g,b} tables (0–255 integers), length 16
-- `r` (number), `g` (number), `b` (number):
--     Target colour to approximate (0–255 integers)
-- returns (table):
--     {colours = {indices...}, ratio = number}
--       · ratio ∈ [0,1]
--         two-colour mode: use Bayer threshold to pick colours[1] or [2]
--       · ratio == 4
--         tri-tone mode: use 2×2 spatial pattern with colours[1..4]
function algorithm.deviseBestMixingPlan(bytesArray, r, g, b)
    -- Track the best solution found so far
    local bestColors = {1, 1}  -- Default: use palette index 1 twice (solid colour)
    local bestRatio = 0.5      -- Default: 50/50 mix
    local leastPenalty = 1e99  -- Start with "infinite" error
    
    -- STRATEGY A: Two-colour mixing search
    
    -- Iterate over all unique pairs of palette colours (i1 ≤ i2 to avoid duplicates)
    for i1 = 1, 16 do
        local c1 = bytesArray[i1]
        local r1, g1, b1 = c1[1], c1[2], c1[3]
        for i2 = i1, 16 do
            local c2 = bytesArray[i2]
            local r2, g2, b2 = c2[1], c2[2], c2[3]
            -- Start with default 50/50 ratio (32/64)
            local ratio = 32
            
            -- If colours differ, solve analytically for the optimal mixing ratio
            -- For each channel: solve c1 + ratio×(c2−c1)/64 = target
            --                   → ratio = 64 × (target − c1) / (c2 − c1)
            -- Take luma-weighted average of the three channel ratios
            if r1 ~= r2 or g1 ~= g2 or b1 ~= b2 then
                ratio = (
                    (r2 ~= r1 and 299 * 64 * (r - r1) / (r2 - r1) or 0) +  -- R channel contribution
                    (g2 ~= g1 and 587 * 64 * (g - g1) / (g2 - g1) or 0) +  -- G channel (most weight)
                    (b2 ~= b1 and 114 * 64 * (b - b1) / (b2 - b1) or 0)    -- B channel
                ) / (
                    (r2 ~= r1 and 299 or 0) +  -- Sum of active weights for normalisation
                    (g2 ~= g1 and 587 or 0) +
                    (b2 ~= b1 and 114 or 0)
                )
                -- Clamp to valid threshold matrix range [0, 63]
                ratio = clamp(ratio, 0, 63)
            end
            
            -- Compute the actual mixed colour this ratio would produce (in sRGB)
            local mr = r1 + ratio * (r2 - r1) / 64
            local mg = g1 + ratio * (g2 - g1) / 64
            local mb = b1 + ratio * (b2 - b1) / 64
            -- Convert to [0,1] for error evaluation
            local normRatio = ratio / 64
            
            -- Evaluate total penalty: match error + psychovisual penalty
            local penalty = algorithm.evaluateMixingError(
                r, g, b, mr, mg, mb,     -- target vs. mixed result
                r1, g1, b1, r2, g2, b2,  -- component colours
                normRatio
            )
            
            -- Keep this plan if it's better than anything seen so far
            if penalty < leastPenalty then
                leastPenalty = penalty
                bestColors = {i1, i2}  -- Store palette indices (1-based)
                bestRatio = normRatio  -- Store normalised ratio [0,1]
            end
            
            -- STRATEGY B: Tri-tone mixing search (3 colours in 2×2 pattern)
            
            -- Only test if we have two distinct base colours to build upon
            if i1 ~= i2 then
                for i3 = 1, 16 do
                    -- Skip if third colour duplicates one of the base pair
                    if i3 ~= i1 and i3 ~= i2 then
                        local c3 = bytesArray[i3]
                        local r3, g3, b3 = c3[1], c3[2], c3[3]
                        
                        -- Compute mixed colour for fixed 2×2 layout:
                        --   [c3][c1] → 50% c3, 25% c1, 25% c2
                        --   [c2][c3]
                        tr = (r1 + r2 + r3 * 2) / 4
                        tg = (g1 + g2 + g3 * 2) / 4
                        tb = (b1 + b2 + b3 * 2) / 4
                        
                        -- Evaluate tri-tone penalty:
                        --   · Main term: how well the 4-pixel average matches targe
                        --   · Tiny penalties to discourage harsh juxtapositions:
                        --     · c1 vs c2 contrast (×0.025)
                        --     · average(c1,c2) vs c3 contrast (×0.025)
                        local penaltyT = (
                            algorithm.colourPerceptualDistance(r, g, b, tr, tg, tb) +
                            algorithm.colourPerceptualDistance(r1, g1, b1, r2, g2, b2) * 0.025 +
                            algorithm.colourPerceptualDistance((r1+r2)/2, (g1+g2)/2, (b1+b2)/2, r3, g3, b3) * 0.025
                        )
                        
                        -- Keep this tri-tone plan if it beats the current best
                        if penaltyT < leastPenalty then
                            leastPenalty = penaltyT
                            -- Store 2×2 layout indices (row-major order):
                            -- [0][0]=i3, [0][1]=i1, [1][0]=i2, [1][1]=i3
                            bestColors = {i3, i1, i2, i3}
                            bestRatio = 4  -- Special flag: signals tri-tone mode to renderer
                        end
                    end
                end
            end
        end
    end
    
    -- Return the optimal plan for this pixel
    return {colours=bestColors, ratio=bestRatio}
end

-- Export the module
return algorithm