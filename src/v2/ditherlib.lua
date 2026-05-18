-- ===========================================================================
-- `ditherlib.lua` — Yliluoma's Ordered Dithering (Algorithm 1 + Enhancements)
-- ===========================================================================
-- 
-- A LuaJIT/FFI wrapper for the C++ dithering backend.
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

-- =================================================
-- FFI Bindings: Interface to the C++ shared library
-- =================================================
-- 
-- MixingPlan struct mirrors the C++ definition exactly.
-- Note: colours[] array is 0-indexed in C, but stores 1-based palette indices for
-- seamless Lua table lookup.
local ffi = require("ffi")
ffi.cdef(
    "typedef struct {\n"..
    "    unsigned colours[4];\n"..  -- 1-based palette indices for Lua
    "    double ratio;\n"..         -- [0,1] two-colour, or 4.0 for tri-tone
    "} MixingPlan;\n\n"..
    "int deviseBestMixingPlan(uint8_t bytesArray[16][3], MixingPlan* plan, const int r, const int g, const int b);"
)
local clib = ffi.load("./ditherlib_c.so")

-- =========================================
-- 8×8 Bayer ordered dither threshold matrix
-- =========================================
-- 
-- Ordered dither matrix used to spatially distribute two palette colours.
-- Values are normalised to [0, 63/64] to represent threshold proportions.
-- The pattern is designed to minimise low-frequency banding and avoid clumping.
-- Indexing: thresholdMap[(x%8) + (y%8)*8 + 1] for 1-based Lua access.
local thresholdMap = {
    0/64, 48/64, 12/64, 60/64, 3/64, 51/64, 15/64, 63/64,
    32/64, 16/64, 44/64, 28/64, 35/64, 19/64, 47/64, 31/64,
    8/64, 56/64, 4/64, 52/64, 11/64, 59/64, 7/64, 55/64,
    40/64, 24/64, 36/64, 20/64, 43/64, 27/64, 39/64, 23/64,
    2/64, 50/64, 14/64, 62/64, 1/64, 49/64, 13/64, 61/64,
    34/64, 18/64, 46/64, 30/64, 33/64, 17/64, 45/64, 29/64,
    10/64, 58/64, 6/64, 54/64, 9/64, 57/64, 5/64, 53/64,
    42/64, 26/64, 38/64, 22/64, 41/64, 25/64, 37/64, 21/64
}

-- Module table: exports public functions
local ditherlib = {}

-- ===========================================================================
-- ditheredImage: Main entry point — process an `ImageData` with the dithering
--                algorithm
-- ===========================================================================
-- 
-- Parameters:
--   imageData: LÖVE `ImageData` (source pixels)
--   palette: Table of {r,g,b} in [0,1] float format (16 entries expected)
--   opts: Optional settings table
--     · ratio: Processing downscale factor (1 = full res, >1 = faster preview)
--     · upscale: If true, stretch output back to original dimensions
--
-- Returns: LÖVE `Image` ready for rendering
--
-- Performance note: The O(P³) algorithm is CPU-heavy. Using ratio > 1 with GPU-
-- accelerated downscaling provides a fast preview workflow.
function ditherlib.ditheredImage(imageData, palette, opts)
    local opts = opts or {}
    local ratio = opts.ratio or 1
    local upscale = opts.upscale ~= false
    
    -- Prepare palette for C++ FFI: Convert [0,1] floats → [0,255] `uint8_t`.
    -- C++ expects uint8_t[16][3]. Lua palette is 1-based {r,g,b} in [0,1].
    local palFFI = ffi.new("uint8_t[16][3]")
    for i = 1, 16 do
        -- `love.math.colorToBytes` converts [0,1] → [0,255] integers
        local r, g, b = love.math.colorToBytes(palette[i])
        palFFI[i-1][0] = r  -- C arrays are 0-indexed: palette[1] → palFFI[0]
        palFFI[i-1][1] = g
        palFFI[i-1][2] = b
    end
    
    local origW, origH = imageData:getDimensions()
    -- Target processing resolution (downscaled if ratio > 1 for speed)
    local procW, procH = math.floor(origW/ratio), math.floor(origH/ratio)
    
    -- Optional GPU-accelerated downscaling for preview mode.
    -- Downscaling via LÖVE's canvas is vastly faster than CPU pixel averaging.
    local procImageData
    if ratio > 1 then
        local canvas = love.graphics.newCanvas(procW, procH)
        love.graphics.setCanvas(canvas)
        love.graphics.clear()
        
        -- Draw source image scaled down to canvas dimensions
        local tempImage = love.graphics.newImage(imageData)
        love.graphics.draw(tempImage, 0, 0, 0, procW/origW, procH/origH)
        
        love.graphics.setCanvas()  -- Reset to default render target
        procImageData = canvas:newImageData()  -- Read back processed pixels
        tempImage:release()  -- Free GPU memory
    else
        procImageData = imageData  -- Skip downscaling, process at full res
    end
    
    -- Output buffer allocation (matches original or processed dimensions)
    local outW, outH = upscale and origW or procW, upscale and origH or procH
    local ditheredData = love.image.newImageData(outW, outH)
    -- Allocate MixingPlan struct ONCE to avoid per-pixel GC pressure.
    -- Initialised with safe defaults (1-based indices, 0.5 ratio)
    local plan = ffi.new("MixingPlan", {{1, 1, 1, 1}, 0.5})
    
    -- Per-pixel dithering loop (main computation)
    for py = 1, procH do
        for px = 1, procW do
            -- Read source pixel. LÖVE uses 0-based indexing for `ImageData`.
            local r, g, b, a = procImageData:getPixel(px-1, py-1)
            -- Convert [0,1] floats → [0,255] integers for the perceptual algorithm
            r, g, b = love.math.colorToBytes(r, g, b)
            
            -- Call optimised C++ function to find best palette mix
            -- `plan` is populated in-place with {colours[4], ratio}
            clib.deviseBestMixingPlan(palFFI, plan, r, g, b)
            
            local palIdx  -- Will hold the final 1-based palette index to output
            
            -- Determine which palette index to output based on `plan.ratio` mode
            if plan.ratio == 4.0 then
                -- Tri-tone mode: Use fixed 2×2 repeating pattern
                -- Layout stored in plan.colours[0..3] as:
                --   [0][0]=colours[0], [0][1]=colours[1]
                --   [1][0]=colours[2], [1][1]=colours[3]
                -- Index calculation: ((y%2)*2 + (x%2)) gives 0,1,2,3 for the 2×2 tile
                -- NOTE: `plan.colours[]` is 0-indexed C array, but stores 1-based indices
                palIdx = plan.colours[((py-1)%2)*2+((px-1)%2)]
            else
                -- Two-colour mode: Compare Bayer threshold to planned ratio
                -- `thresholdMap` is 1-based Lua table: index = (x%8) + (y%8)*8 + 1
                local mapVal = thresholdMap[((px-1)%8)+((py-1)%8)*8+1]
                -- If threshold < ratio → output colours[1] (second colour)
                -- Else → output colours[0] (first colour)
                -- NOTE: plan.colours[] is 0-indexed C array
                palIdx = plan.colours[mapVal < plan.ratio and 1 or 0] + 0
            end
            
            -- Fetch the actual [0,1] float colour for LÖVE rendering
            local pc = palette[palIdx]
            
            -- Write to output buffer (with optional upscaling expansion)
            if upscale then
                -- Expand the processed pixel to a ratio×ratio block in the output
                local ox1, oy1 = math.floor((px-1)*ratio) + 1, math.floor((py-1)*ratio) + 1
                local ox2, oy2 = math.min(math.floor(px*ratio), origW), math.min(math.floor(py*ratio), origH)
                for oy = oy1, oy2 do
                    for ox = ox1, ox2 do
                        -- LÖVE `ImageData:setPixel` uses 0-based indexing
                        ditheredData:setPixel(ox-1, oy-1, pc[1], pc[2], pc[3], a)
                    end
                end
            else
                -- Direct 1:1 pixel write (output matches processing resolution)
                ditheredData:setPixel(px-1, py-1, pc[1], pc[2], pc[3], a)
            end
        end
    end
    
    -- Convert raw pixel data to a GPU-textured `Image` for fast rendering
    return love.graphics.newImage(ditheredData)
end

-- Export the module
return ditherlib