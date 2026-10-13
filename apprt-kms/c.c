// C headers for the kms apprt, translated into the `kms_c` Zig module by
// build.zig. EGL comes from Ghostty's glad bindings (`opengl` module)
// instead, since glad's EGL header refuses to coexist with <EGL/egl.h>.
#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/eventfd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/timerfd.h>
#include <linux/input-event-codes.h>

#include <xf86drm.h>
#include <xf86drmMode.h>
#include <gbm.h>

#include <libinput.h>
#include <libudev.h>
#include <libseat.h>

#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-compose.h>
#include <xkbcommon/xkbcommon-keysyms.h>

#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
