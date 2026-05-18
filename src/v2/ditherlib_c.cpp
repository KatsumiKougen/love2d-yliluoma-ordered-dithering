// ==========================================================
// ditherlib_c.cpp — Yliluoma Ordered Dithering (C++ Backend)
// ==========================================================
// 
// Implements Joel "Bisqwit" Yliluoma's arbitrary-palette positional dithering.
// 
// Features:
// 
// · Perceptually-weighted colour comparison (CCIR 601 luma)
// · Psychovisual penalty to avoid harsh colour juxtapositions
// · Analytical ratio solver (O(1) per pair instead of brute-force 64)
// · Optional tri-tone 2×2 dithering for smoother gradients
// 
// Build (Linux):
//   g++ -std=c++20 -shared -fPIC -O3 -o ditherlib_c.so ditherlib_c.cpp
// 
// Note: All palette indices returned are 1-based for Lua compatibility.

#include <cmath>
#include <cstdint>

extern "C" {
    // ==================================================
    // MixingPlan: Result structure passed to Lua via FFI
    // ==================================================
    // 
    // colours[0..3]: Palette indices (1-based for Lua compatibility)
    //   - Two-colour mode: uses colours[0] and colours[1]
    //   - Tri-tone mode: uses all 4 in a 2×2 spatial pattern
    // ratio:
    //   - [0.0, 1.0]: Two-colour mixing proportion (threshold comparison value)
    //   - 4.0: Special flag signalling tri-tone mode to the renderer
    typedef struct {
        unsigned colours[4];
        double ratio;
    } MixingPlan;
    
    // ===================================================================
    // colourPerceptualDistance: Perceptually-weighted RGB distance metric
    // ===================================================================
    // 
    // Uses CCIR 601 luma coefficients (0.299R + 0.587G + 0.114B) to match human
    // vision, where brightness differences are ~2× more noticeable than chroma shifts.
    //
    // Formula:
    //   error = 0.75 × (weighted chroma MSE) + 1.0 × (luma difference)²
    // 
    // Returns: Scalar error value (lower = more perceptually similar)
    static double colourPerceptualDistance(int r1, int g1, int b1, int r2, int g2, int b2) {
        double dr = (r1 - r2) / 255.0;
        double dg = (g1 - g2) / 255.0;
        double db = (b1 - b2) / 255.0;
        
        // Compute luma difference using CCIR 601 coefficients
        // Denominator: 255 × 1000 keeps result in [-1, 1] after integer math
        double lumaDiff = ((r1 - r2) * 299 + (g1 - g2) * 587 + (b1 - b2) * 114) / 255000.0;
        
        // Combine weighted chroma MSE (75% weight) + pure luma error (100% weight)
        return (dr * dr * 0.299 + dg * dg * 0.587 + db * db * 0.114) * 0.75 + lumaDiff * lumaDiff;
    }
    
    // ======================================================
    // evaluateMixingError: Two-term psychovisual error model
    // ======================================================
    // 
    // Combines:
    //   1. Match error: How well the mixed colour approximates the target
    //   2. Psychovisual penalty: Discourages mixing visually distant colours
    // 
    // The penalty is scaled by (|ratio−0.5| + 0.5):
    //   · ratio = 0.5 → factor = 0.5 (MAX penalty: 50/50 checkerboards are most visible)
    //   · ratio = 0.0 or 1.0 → factor = 1.0 (MIN penalty: one colour dominates)
    // 
    // This biases the planner toward mixing similar colours for smoother patterns,
    // while still allowing high-contrast mixes when necessary for accuracy.
    static double evaluateMixingError(
        const int tr, const int tg, const int tb,  // Target colour (desired output)
        const int mr, const int mg, const int mb,  // Mixed result (what c1+c2 actually produces)
        const int c1r, const int c1g, const int c1b,  // Component colour 1
        const int c2r, const int c2g, const int c2b,  // Component colour 2
        const double ratio  // Mixing proportion [0.0, 1.0]
    ) {
        return (
            colourPerceptualDistance(tr, tg, tb, mr, mg, mb) +  // Match error
            colourPerceptualDistance(c1r, c1g, c1b, c2r, c2g, c2b) *  // Penalty base
            0.1 * (std::abs(ratio-0.5) + 0.5)  // Ratio-dependent scaling
        );
    }
    
    // ===========================================================================
    // deviseBestMixingPlan: Core planner — find optimal palette mix for one pixel
    // ===========================================================================
    // 
    // Searches two strategies:
    //   A) Two-colour mixing: Find pair (c1,c2) + ratio minimizing error
    //   B) Tri-tone mixing: Find triple (c1,c2,c3) for fixed 2×2 pattern (50%/25%/25%)
    //
    // Uses analytical ratio solver instead of brute-forcing 64 values:
    //   ratio = weighted_average( 64 × (target − c1) / (c2 − c1) ) per channel
    // Weights use CCIR 601 luma coefficients to prioritize perceptually important channels.
    // 
    // IMPORTANT: All palette indices written to `plan` are 1-based for Lua compatibility.
    int deviseBestMixingPlan(uint8_t bytesArray[16][3], MixingPlan* plan, int r, int g, int b) {
        if (!bytesArray || !plan)
            return -1;
        
        // Track best solution found (initialised to safe defaults)
        // NOTE: bestColours stores 1-based indices for Lua; subtract 1 when indexing bytesArray
        unsigned int bestColours[4] = {1, 1, 1, 1};
        double bestRatio = 0.5;      // Default: 50/50 two-colour mix
        double leastPenalty = 1e99;  // Start with "infinite" error
        
        // STRATEGY A: Two-colour mixing search (O(P²) for P=16 palette size)
        for (int i0 = 0; i0 < 16; i0++) {
            for (int i1 = 1; i1 < 16; i1++) {  // Start at i0 to avoid duplicate pairs
                // Extract component colours from palette (0–255 range)
                int r0 = bytesArray[i0][0], g0 = bytesArray[i0][1], b0 = bytesArray[i0][2];
                int r1 = bytesArray[i1][0], g1 = bytesArray[i1][1], b1 = bytesArray[i1][2];
                // Default to 50/50 ratio (32/64) if colours are identical
                int ratio = 32;
                
                // Analytical ratio solver: compute optimal mixing proportion
                // For each channel: solve c1 + ratio×(c2−c1)/64 = target
                //                   → ratio = 64 × (target − c1) / (c2 − c1)
                // Take luma-weighted average of the three channel ratios
                if (i0 != i1) {
                    int denom = (r1 != r0 ? 299 : 0) + (g1 != g0 ? 587 : 0) + (b1 != b0 ? 114 : 0);
                    if (denom > 0)
                        ratio = (
                            (r1 != r0 ? 299 * 64 * (r - r0) / (r1 - r0) : 0) +  // R channel (299 weight)
                            (g1 != g0 ? 587 * 64 * (g - g0) / (g1 - g0) : 0) +  // G channel (587 weight, most important)
                            (b1 != b0 ? 114 * 64 * (b - b0) / (b1 - b0) : 0)    // B channel (114 weight)
                        ) / denom;
                    // Clamp to valid threshold matrix range [0, 63]
                    if (ratio < 0)
                        ratio = 0;
                    else if (ratio > 63)
                        ratio = 63;
                }
                
                // Compute the actual mixed colour this ratio would produce (in sRGB)
                int mr = r0 + ratio * (r1 - r0) / 64;
                int mg = g0 + ratio * (g1 - g0) / 64;
                int mb = b0 + ratio * (b1 - b0) / 64;
                double normRatio = ratio / 64.0;  // Convert to [0,1] for error evaluation
                
                // Evaluate total penalty: match error + psychovisual penalty
                double penalty = evaluateMixingError(
                    r, g, b, mr, mg, mb,     // Target vs. mixed result
                    r0, g0, b0, r1, g1, b1,  // Component colours
                    normRatio
                );
                
                // Keep this plan if it's better than anything seen so far
                if (penalty < leastPenalty) {
                    leastPenalty = penalty;
                    // Store 1-based indices for Lua compatibility (+1 offset)
                    bestColours[0] = i0 + 1;
                    bestColours[1] = i1 + 1;
                    bestRatio = ratio / 64.0;
                }
                
                // STRATEGY B: Tri-tone mixing search (3 colours in fixed 2×2 pattern)
                // Only test if we have two distinct base colours to build upon
                if (i0 != i1) {
                    for (int i2 = 0; i2 < 16; i2++) {
                        if(i2 == i1 || i2 == i0)
                            continue;  // Skip duplicates
                        
                        int r2 = bytesArray[i2][0], g2 = bytesArray[i2][1], b2 = bytesArray[i2][2];
                        
                        // Compute mixed color for fixed 2×2 layout:
                        //   [c2][c0]   → 50% c2, 25% c0, 25% c1
                        //   [c1][c2]
                        // Formula: (c0 + c1 + 2×c2) / 4
                        int tr = (r0 + r1 + r2 * 2) / 4;
                        int tg = (g0 + g1 + g2 * 2) / 4;
                        int tb = (b0 + b1 + b2 * 2) / 4;
                        
                        // Evaluate tri-tone penalty:
                        //   · Main term: how well the 4-pixel average matches target
                        //   · Tiny penalties (×0.025) to discourage harsh juxtapositions:
                        //     · c0 vs c1 contrast
                        //     · average(c0,c1) vs c2 contrast
                        double penaltyT = (
                            colourPerceptualDistance(r, g, b, tr, tg, tb) +
                            colourPerceptualDistance(r0, g0, b0, r1, g1, b1) * 0.025 +
                            colourPerceptualDistance((r0+r1)/2, (g0+g1)/2, (b0+b1)/2, r2, g2, b2) * 0.025
                        );
                        
                        // Keep this tri-tone plan if it beats the current best
                        if (penaltyT < leastPenalty) {
                            leastPenalty = penaltyT;
                            // Store 2×2 layout indices (row-major order), 1-based for Lua:
                            // [0][0]=i2+1, [0][1]=i0+1, [1][0]=i1+1, [1][1]=i2+1
                            bestColours[0] = i2 + 1;
                            bestColours[1] = i1 + 1;
                            bestColours[2] = i0 + 1;
                            bestColours[3] = i2 + 1;
                            bestRatio = 4.0;  // Special flag: signals tri-tone mode to renderer
                        }
                    }
                }
            }
        }
        
        // Write final result to FFI struct (caller reads this via LuaJIT)
        plan->colours[0] = bestColours[0];
        plan->colours[1] = bestColours[1];
        plan->colours[2] = bestColours[2];
        plan->colours[3] = bestColours[3];
        plan->ratio = bestRatio;
        
        return 0;
    }
}