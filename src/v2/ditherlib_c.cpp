// Linux:
// g++ -std=c++20 -shared -fPIC -O3 -o ditherlib_c.so ditherlib_c.cpp

#include <array>
#include <cmath>
#include <cstdint>

#define d(x) x/64.0
constexpr std::array<double, 64> thresholdMap = {
    d( 0), d(48), d(12), d(60), d( 3), d(51), d(15), d(63),
    d(32), d(16), d(44), d(28), d(35), d(19), d(47), d(31),
    d( 8), d(56), d( 4), d(52), d(11), d(59), d( 7), d(55),
    d(40), d(24), d(36), d(20), d(43), d(27), d(39), d(23),
    d( 2), d(50), d(14), d(62), d( 1), d(49), d(13), d(61),
    d(34), d(18), d(46), d(30), d(33), d(17), d(45), d(29),
    d(10), d(58), d( 6), d(54), d( 9), d(57), d( 5), d(53),
    d(42), d(26), d(38), d(22), d(41), d(25), d(37), d(21)
};
#undef d

extern "C" {
    typedef struct {
        unsigned colours[4];
        double ratio;
    } MixingPlan;
    
    static double colourPerceptualDistance(int r1, int g1, int b1, int r2, int g2, int b2) {
        double dr = (r1 - r2) / 255.0;
        double dg = (g1 - g2) / 255.0;
        double db = (b1 - b2) / 255.0;
        double lumaDiff = ((r1 - r2) * 299 + (g1 - g2) * 587 + (b1 - b2) * 114) / 255000.0;
        return (dr * dr * 0.299 + dg * dg * 0.587 + db * db * 0.114) * 0.75 + lumaDiff * lumaDiff;
    }
    
    static double evaluateMixingError(
        const int tr, const int tg, const int tb,
        const int mr, const int mg, const int mb,
        const int c1r, const int c1g, const int c1b,
        const int c2r, const int c2g, const int c2b,
        const double ratio
    ) {
        return (
            colourPerceptualDistance(tr, tg, tb, mr, mg, mb) +
            colourPerceptualDistance(c1r, c1g, c1b, c2r, c2g, c2b) *
            0.1 * (std::abs(ratio-0.5) + 0.5)
        );
    }
    
    int deviseBestMixingPlan(uint8_t bytesArray[16][3], MixingPlan* plan, int r, int g, int b) {
        if (!bytesArray || !plan)
            return -1;
        
        // MixingPlan result = {{1, 1, 1, 1}, 0.5};
        unsigned int bestColours[4] = {1, 1, 1, 1};
        double bestRatio = 0.5;
        double leastPenalty = 1e99;
        
        for (int i0 = 0; i0 < 16; i0++) {
            for (int i1 = 1; i1 < 16; i1++) {
                int r0 = bytesArray[i0][0], g0 = bytesArray[i0][1], b0 = bytesArray[i0][2];
                int r1 = bytesArray[i1][0], g1 = bytesArray[i1][1], b1 = bytesArray[i1][2];
                int ratio = 32;
                
                if (i0 != i1) {
                    int denom = (r1 != r0 ? 299 : 0) + (g1 != g0 ? 587 : 0) + (b1 != b0 ? 114 : 0);
                    if (denom > 0)
                        ratio = (
                            (r1 != r0 ? 299 * 64 * (r - r0) / (r1 - r0) : 0) +
                            (g1 != g0 ? 587 * 64 * (g - g0) / (g1 - g0) : 0) +
                            (b1 != b0 ? 114 * 64 * (b - b0) / (b1 - b0) : 0)
                        ) / denom;
                    if (ratio < 0)
                        ratio = 0;
                    else if (ratio > 63)
                        ratio = 63;
                }
                
                int mr = r0 + ratio * (r1 - r0) / 64;
                int mg = g0 + ratio * (g1 - g0) / 64;
                int mb = b0 + ratio * (b1 - b0) / 64;
                double normRatio = ratio / 64.0;
                
                double penalty = evaluateMixingError(
                    r, g, b, mr, mg, mb,
                    r0, g0, b0, r1, g1, b1,
                    normRatio
                );
                
                if (penalty < leastPenalty) {
                    leastPenalty = penalty;
                    bestColours[0] = i0 + 1;
                    bestColours[1] = i1 + 1;
                    bestRatio = ratio / 64.0;
                }
                
                if (i0 != i1) {
                    for (int i2 = 0; i2 < 16; i2++) {
                        if(i2 == i1 || i2 == i0)
                            continue;
                        
                        int r2 = bytesArray[i2][0], g2 = bytesArray[i2][1], b2 = bytesArray[i2][2];

                        int tr = (r0 + r1 + r2 * 2) / 4;
                        int tg = (g0 + g1 + g2 * 2) / 4;
                        int tb = (b0 + b1 + b2 * 2) / 4;
                        
                        double penaltyT = (
                            colourPerceptualDistance(r, g, b, tr, tg, tb) +
                            colourPerceptualDistance(r0, g0, b0, r1, g1, b1) * 0.025 +
                            colourPerceptualDistance((r0+r1)/2, (g0+g1)/2, (b0+b1)/2, r2, g2, b2) * 0.025
                        );
                        
                        if (penaltyT < leastPenalty) {
                            leastPenalty = penaltyT;
                            bestColours[0] = i2 + 1;
                            bestColours[1] = i1 + 1;
                            bestColours[2] = i0 + 1;
                            bestColours[3] = i2 + 1;
                            bestRatio = 4.0;
                        }
                    }
                }
            }
        }
        
        plan->colours[0] = bestColours[0];
        plan->colours[1] = bestColours[1];
        plan->colours[2] = bestColours[2];
        plan->colours[3] = bestColours[3];
        plan->ratio = bestRatio;
        
        return 0;
    }
}