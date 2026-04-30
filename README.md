# About `love2d-yliluoma-ordered-dithering`

This is a LÖVE program that executes a dithering algorithm capable of handling arbitrary, user-specified colour sets, based on [the work of Joel "Bisqwit" Yliluoma](https://bisqwit.iki.fi/story/howto/dither/jy/). Its primary function is to convert truecolour animations into paletted ones, prioritising visual consistency by minimising unintended motion artifacts.

The program relies on a pure-Lua implementation, with logical code layout and thorough inline explanations to facilitate learning.

Even though this algorithm is applicable to retro graphics and GIF animations, I chose not to implement animation handling since getting the basic implementation to run was challenging enough. It still serves retro designers well, however, by generating attractive visuals that stay within the bounds of limited palettes.

> [!WARNING]
> Since Lua interprets code at runtime, it will always trail behind the performance of native C/C++ applications, a fact that holds true even within the LuaJIT-enabled LÖVE environment. This disparity, along with the current code's unoptimised state, leads to noticeable slowdowns. To compensate, I implemented a feature that reduces the image resolution before dithering, thereby speeding up the overall computation.

To launch the application, run:

```sh
love . [filename]
```

By default, if no specific file is provided, the program looks for `Lenna.png` in the same folder as this `README`.

The program includes two default palettes: `c64palette.lua` and `pico8palette.lua`. I added the C64 palette because that scheme evokes the unique character of the original hardware, despite being a bit dull; whereas the PICO-8 selection is visually superior. I plan to expand with more palettes and increased colour depth in later versions.