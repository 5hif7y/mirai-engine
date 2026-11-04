//! mirai frame Foliage_Wind_Frame foliage_wind
// The winds of the world in the constants of each view (volume.Gpu_Wind), and
// the benders nearest the view (foliage.Gpu_Wind_Frame).
#ifndef FOLIAGE_WIND_SLANG
#define FOLIAGE_WIND_SLANG
#include "volume.slang"
#define FOLIAGE_BENDERS 8
#define FOLIAGE_BEND_LEAN_MAX 1.4 // foliage.BEND_LEAN_MAX
struct Foliage_Bender_Frame {
    float3 position; // relative to the origin of the view
    float radius;
    float3 previous; // where it was the frame before
    float lean;      // radians at its middle
};
struct Foliage_Wind_Frame {
    Gpu_Wind wind;
    Foliage_Bender_Frame benders[FOLIAGE_BENDERS];
    uint4 count;     // x: of benders
};
#endif
