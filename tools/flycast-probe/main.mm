// Compiles the Dreamcast host for macOS. Does not need a disc or a BIOS.
#import "../../Core/dreamcast/twinplay_flycast.h"
#import <stdio.h>

int main(void) {
    printf("flycast available=%d cpu=%s renderer=%s\n",
           twinplay_dc_available(), twinplay_dc_cpu_mode(), twinplay_dc_renderer());
    return 0;
}
