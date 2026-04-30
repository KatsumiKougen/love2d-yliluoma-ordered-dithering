-- ========================================
-- `main.lua`: Yliluoma's Ordered Dithering
-- ========================================
-- 
-- Demonstrates offline/preview dithering using `algorithm.lua`.
-- Usage: Run with `love . [image.png]`.
--        Press TAB to switch views.

local algorithm = require("algorithm")

-- Global handles for the original and dithered `Image` objects
local image, dithered
-- View toggle state: 1 = original, 2 = dithered
local current = 1

-- Ordered dither matrix used to spatially distribute two palette colours.
-- Values are normalised to [0, 63/64] to represent threshold proportions.
-- The pattern is designed to minimise low-frequency banding and avoid clumping.
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


-- Load the color palette from a modular external file.
-- The external file should return a table with a `palette` key containing an array
-- of {r, g, b} triplets in normalised [0, 1] float format.
-- This separation keeps the main script clean and allows easy palette swapping.
local palette = require("pico8palette").palette
-- Generate a parallel [0, 255] integer version of the palette for `algorithm.lua`.
local palBytes = {}
for i, c in ipairs(palette) do
    palBytes[i] = {love.math.colorToBytes(c)}
end

-- Generate a dithered LÖVE Image from source `ImageData`.
-- 
-- `imageData` (ImageData): Source LÖVE `ImageData`
-- `paletteBytes` (table[number, ...]): Palette as array of {r,g,b} [0-255] integers
-- `opts` (table[ratio[number?], upscale[boolean?]]):
--     {ratio=number, upscale=boolean}
--       · `ratio`: Processing downscale factor (1 = full res, >1 = faster)
--       · `upscale`: If true, output matches original dimensions
-- returns (Image): Processed image
local function ditheredImage(imageData, paletteBytes, opts)
    local opts = opts or {}
    local ratio = opts.ratio or 1
    local upscale = opts.upscale ~= false
    
    local origW, origH = imageData:getDimensions()
    -- Target processing resolution (downscaled if ratio > 1)
    local procW, procH = math.floor(origW/ratio), math.floor(origH/ratio)
    
    -- The O(P³) algorithm is heavy. Downscaling via GPU hardware is vastly faster than
    -- CPU pixel averaging, and provides a quick visual preview.
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
    
    -- Output buffer allocation
    local outW, outH = upscale and origW or procW, upscale and origH or procH
    local ditheredData = love.image.newImageData(outW, outH)
    
    -- Per-pixel dithering loop
    for py = 1, procH do
        for px = 1, procW do
            -- Read source pixel. LÖVE uses 0-based indexing for `ImageData.
            local r, g, b, a = procImageData:getPixel(px-1, py-1)
            -- Convert to [0,255] integers for the perceptual algorithm
            r, g, b = love.math.colorToBytes(r, g, b)
            
            -- 2. Find optimal palette mix for this pixel
            local plan = algorithm.deviseBestMixingPlan(paletteBytes, r, g, b)
            local palIdx
            
            -- 3. Determine which palette index to output
            if plan.ratio == 4 then
                -- Tri-tone mode: 2×2 repeating pattern
                -- Maps (x,y) to indices 1,2,3,4 based on 2×2 quadrant
                palIdx = plan.colours[((py-1)%2)*2+((px-1)%2)+1]
            else
                -- Two-colour mode: Compare Bayer threshold to planned ratio
                -- ((x%8) + (y%8)*8 + 1) indexes into the 1-based Lua array
                local mapVal = thresholdMap[((px-1)%8)+((py-1)%8)*8+1]
                palIdx = plan.colours[mapVal < plan.ratio and 2 or 1]
            end
            
            -- Fetch the actual [0,1] float color for LÖVE rendering
            local pc = palette[palIdx]
            
            -- 4. Write to output buffer (with optional upscaling expansion)
            if upscale then
                -- Expand the processed pixel to a ratio×ratio block
                local ox1, oy1 = math.floor((px-1)*ratio) + 1, math.floor((py-1)*ratio) + 1
                local ox2, oy2 = math.min(math.floor(px*ratio), origW), math.min(math.floor(py*ratio), origH)
                for oy = oy1, oy2 do
                    for ox = ox1, ox2 do
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

-- Called once at startup.
-- Loads assets and precomputes the dithered image.
function love.load(args)
    -- Use first CLI argument as image path, fallback to "Lenna.png"
    local sampleFileName = args[1] or "Lenna.png"
    
    love.window.setTitle("Loading...")
    
    -- Load source image into CPU memory (`ImageData`) and GPU memory (`Image`)
    local imageData = love.image.newImageData(sampleFileName)
    image = love.graphics.newImage(imageData)
    -- Run dithering pipeline
    --   · ratio=n: Process at 1/nth resolution (1/(n^2)th pixels) for speed
    --   · upscale=true: Stretch result back to original dimensions for comparison
    dithered = ditheredImage(imageData, palBytes, {ratio=4, upscale=true})
    
    -- Resize window to exactly match the source image dimensions
    love.window.setMode(image:getDimensions())
end

-- Called every frame to draw the screen.
function love.draw()
    love.window.setTitle("Yliluoma's ordered dithering algorithm in LÖVE")
    
    -- Toggle between original and dithered image
    if current == 1 then
        love.graphics.draw(image)
    elseif current == 2 then
        love.graphics.draw(dithered)
    end
end

-- Handle keyboard input. TAB toggles between views.
function love.keypressed(key)
    if key == "tab" then
        current = 3 - current
    end
end