// The system zlib (macOS SDK, or zlib1g-dev on Debian/Ubuntu). PerfectZip uses only raw
// deflate/inflate and crc32 from it; the ZIP format itself is implemented in Swift.
#include <zlib.h>
