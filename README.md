# About `love2d-yliluoma-ordered-dithering`

This is a LÖVE program that executes a dithering algorithm capable of handling arbitrary, user-specified colour sets, based on [the work of Joel "Bisqwit" Yliluoma](https://bisqwit.iki.fi/story/howto/dither/jy/). Its primary function is to convert truecolour animations into paletted ones, prioritising visual consistency by minimising unintended motion artifacts.

The program relies on a pure-Lua implementation, with logical code layout and thorough inline explanations to facilitate learning.

Even though this algorithm is applicable to retro graphics and GIF animations, I chose not to implement animation handling since getting the basic implementation to run was challenging enough. It still serves retro designers well, however, by generating attractive visuals that stay within the bounds of limited palettes.

> [!WARNING]
> Since Lua interprets code at runtime, it will always trail behind the performance of native C/C++ applications, a fact that holds true even within the LuaJIT-enabled LÖVE environment. This disparity, along with the current code's unoptimised state, leads to noticeable slowdowns. To compensate, I implemented a feature that reduces the image resolution before dithering, thereby speeding up the overall computation.

## How to use

To launch the application, run:

```sh
love . [filename]
```

By default, if no specific file is provided, the program looks for `furina.png` in the same folder as this `README`.

## Palettes

The program includes two default palettes: `c64palette.lua` and `pico8palette.lua`. I added the C64 palette because that scheme evokes the unique character of the original hardware, despite being a bit dull; whereas the PICO-8 selection is visually superior. I plan to expand with more palettes and increased colour depth in later versions.

## Examples

> ![](https://images2.imgbox.com/09/49/z5Bq6EZO_o.png)
> 
> **Exhibit A:** `furina.png`, dithered at full resolution.

> ![](https://images2.imgbox.com/d8/b8/gvhtMWCj_o.png)
> 
> **Exhibit B:** `furina.png`, downscaled to 1/4 resolution, dithered, then upscaled back.

> | ![](https://images2.imgbox.com/39/d6/gpO6VZfG_o.png) | ![](https://images2.imgbox.com/80/11/FtM3J0nf_o.png) | ![](https://images2.imgbox.com/9c/6c/aPr3f8b6_o.png) |
> | - | - | - |
> | 1/2 res. | 1/4 res. | 1/8 res. |
> 
> **Exhibit C:** A triptych of side-by-side renderings of an artwork processed with Yliluoma's ordered dithering algorithm, demonstrating how the pre-processing resolution affects the final output.

> ![](https://images2.imgbox.com/ba/77/onLTrwaL_o.png)
> 
> **Exhibit D:** An image of the Cult of Skaro with 1/4 resolution pre-processing and the Commodore 64 (C64) 16-colour palette.

> ![](https://images2.imgbox.com/07/5d/RM63TSZw_o.png)
> 
> **Exhibit E:** The C64 palette and the PICO-8 palette side-by-side. Same code, same resolution, same source, but *completely different visual identities* purely from palette selection.

> ![](https://images2.imgbox.com/b4/8d/Bpu5nrtX_o.png)
> 
> **Exhibit F:** ***Long live Republika Kirbska!***