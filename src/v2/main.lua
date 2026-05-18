-- ========================================
-- `main.lua`: Yliluoma's Ordered Dithering
-- ========================================
-- 
-- Demonstrates offline/preview dithering using `algorithm.lua`.
-- Usage: Run with `love . [image.png]`.
--        Press TAB to switch views.

local dl = require("ditherlib")

-- Global handles for the original and dithered `Image` objects
local image, dithered
-- View toggle state: 1 = original, 2 = dithered
local current = 1

-- Load the color palette from a modular external file.
-- The external file should return a table with a `palette` key containing an array
-- of {r, g, b} triplets in normalised [0, 1] float format.
-- This separation keeps the main script clean and allows easy palette swapping.
local palette = require("pico8palette").palette

-- Called once at startup.
-- Loads assets and precomputes the dithered image.
function love.load(args)
    -- Use first CLI argument as image path, fallback to "furina.png"
    local sampleFileName = args[1] or "furina.png"
    
    love.window.setTitle("Loading...")
    
    -- Load source image into CPU memory (`ImageData`) and GPU memory (`Image`)
    local imageData = love.image.newImageData(sampleFileName)
    image = love.graphics.newImage(imageData)
    -- Run dithering pipeline
    --   · ratio=n: Process at 1/nth resolution (1/(n^2)th pixels) for speed
    --   · upscale=true: Stretch result back to original dimensions for comparison
    dithered = dl.ditheredImage(imageData, palette, {ratio=2, upscale=true})
    
    -- Resize window to exactly match the source image dimensions
    love.window.setMode(image:getDimensions())
end

-- Called every frame to draw the screen.
function love.draw()
    love.window.setTitle("Yliluoma's ordered dithering algorithm in LÖVE — Version 2")
    
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